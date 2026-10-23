"""Proactive Marcel: scheduled checks on followed goals, and the ideas they produce.

For every active goal, a check (a mission run through Hermes) looks at where things stand, on
the goal's cadence. At the end, the model decides: "notify" (worth telling the user now),
"later" (worth keeping in mind, not yet worth a message) or "nothing" (nothing new). Only
"notify" creates an idea, and only within the user's proactivity level and daily limit.

Marcel proposes and prepares only: an idea may carry an action it prepared (an email to send,
a purchase to make), which happens only once the user asks for it in a conversation.
"""

from __future__ import annotations

import secrets
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path

from .memory import DAY, similarity

NEW, SEEN, OPENED, APPROVED, DISMISSED = "new", "seen", "opened", "approved", "dismissed"
IDEA_STATUSES = (NEW, SEEN, OPENED, APPROVED, DISMISSED)
NOTIFY, LATER, NOTHING, FAILED = "notify", "later", "nothing", "failed"
LEVELS = ("off", "quiet", "normal")
# How long after the last check a goal is due again, by cadence.
CADENCE_SECONDS = {"hourly": 3600, "daily": DAY, "weekly": 7 * DAY}
# Checks drift by a few minutes (the scheduler wakes every 15 min): don't wait a whole extra
# period for that. A tenth of the period, at most 30 minutes.
DUE_SLACK = 30 * 60
# In quiet mode, only important ideas get through, at most one a day.
QUIET_MIN_IMPORTANCE, QUIET_DAILY_LIMIT = 4, 1
# An idea this close to a recent or dismissed one isn't shown again.
DUPLICATE_SIMILARITY = 0.6
MAX_TITLE_CHARS, MAX_BODY_CHARS, MAX_ACTION_CHARS, MAX_DETAIL_CHARS = 120, 2000, 300, 3000

IDEA_COLUMNS = ("id", "goal_id", "goal_title", "title", "body", "action", "importance", "status",
                "mission_id", "conversation_id", "created_at", "updated_at", "action_detail")
CHECK_COLUMNS = ("id", "goal_id", "mission_id", "at", "decision", "summary")
DEFAULT_SETTINGS = {"level": "normal", "daily_limit": 2, "max_checks_per_day": 6}


@dataclass
class Idea:
    id: str
    goal_id: str
    goal_title: str
    title: str
    body: str = ""
    action: str = ""
    importance: int = 3
    status: str = NEW
    mission_id: str = ""
    conversation_id: str = ""
    created_at: float = 0.0
    updated_at: float = 0.0
    # Exactly what would be sent or done once the user approves (recipient, message, amount…).
    action_detail: str = ""

    def public(self) -> dict:
        return {c: getattr(self, c) for c in IDEA_COLUMNS}


def is_due(cadence: str, last_run_at: float | None, now: float) -> bool:
    """A goal never checked is due at once; "manual" goals only run on demand."""
    if cadence not in CADENCE_SECONDS:
        return False
    period = CADENCE_SECONDS[cadence]
    return last_run_at is None or now - last_run_at >= period - min(DUE_SLACK, period / 10)


def start_of_day(now: float) -> float:
    t = time.localtime(now)
    return time.mktime((t.tm_year, t.tm_mon, t.tm_mday, 0, 0, 0, 0, 0, -1))


def in_hours(hours: tuple[int, int], now: float) -> bool:
    """Checks run only between these hours (server local time), e.g. (8, 21)."""
    start, end = hours
    hour = time.localtime(now).tm_hour
    return start <= hour < end if start <= end else hour >= start or hour < end


def parse_hours(raw: str) -> tuple[int, int]:
    """MARCEL_PROACTIVE_HOURS="8-21" → (8, 21); anything unreadable means all day."""
    try:
        start, end = (int(part) for part in raw.split("-"))
        if 0 <= start <= 24 and 0 <= end <= 24:
            return start, end
    except ValueError:
        pass
    return 0, 24


class IdeaStore:
    def __init__(self, db_path: Path, max_checks_per_day: int = 6):
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self._default_checks = max_checks_per_day
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        self._db.executescript(
            """CREATE TABLE IF NOT EXISTS ideas (
                id TEXT PRIMARY KEY,
                goal_id TEXT NOT NULL,
                goal_title TEXT NOT NULL DEFAULT '',
                title TEXT NOT NULL,
                body TEXT NOT NULL DEFAULT '',
                action TEXT NOT NULL DEFAULT '',
                importance INTEGER NOT NULL DEFAULT 3,
                status TEXT NOT NULL DEFAULT 'new',
                mission_id TEXT NOT NULL DEFAULT '',
                conversation_id TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS goal_checks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                goal_id TEXT NOT NULL,
                mission_id TEXT NOT NULL DEFAULT '',
                at REAL NOT NULL,
                decision TEXT NOT NULL,
                summary TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS goal_checks_goal ON goal_checks (goal_id);
            CREATE TABLE IF NOT EXISTS proactive_settings (name TEXT PRIMARY KEY, value TEXT NOT NULL);"""
        )
        # Columns added after the first version.
        if "action_detail" not in {row[1] for row in self._db.execute("PRAGMA table_info(ideas)")}:
            self._db.execute("ALTER TABLE ideas ADD COLUMN action_detail TEXT NOT NULL DEFAULT ''")
        self._db.commit()

    # MARK: Settings

    def settings(self) -> dict:
        stored = dict(self._db.execute("SELECT name, value FROM proactive_settings"))
        values = DEFAULT_SETTINGS | {"max_checks_per_day": self._default_checks}
        return {name: (stored[name] if name == "level" else int(stored[name])) if name in stored else default
                for name, default in values.items()}

    def update_settings(self, **changes) -> dict:
        for name, value in changes.items():
            if name in DEFAULT_SETTINGS and value is not None:
                self._db.execute("INSERT OR REPLACE INTO proactive_settings (name, value) VALUES (?, ?)",
                                 (name, str(value)))
        self._db.commit()
        return self.settings()

    def daily_limit(self) -> int:
        """Ideas allowed today, given the proactivity level."""
        settings = self.settings()
        if settings["level"] == "off":
            return 0
        if settings["level"] == "quiet":
            return min(settings["daily_limit"], QUIET_DAILY_LIMIT)
        return settings["daily_limit"]

    def min_importance(self) -> int:
        return QUIET_MIN_IMPORTANCE if self.settings()["level"] == "quiet" else 1

    # MARK: Checks

    def record_check(self, goal_id: str, mission_id: str, decision: str, summary: str = "") -> dict:
        now = time.time()
        cursor = self._db.execute(
            "INSERT INTO goal_checks (goal_id, mission_id, at, decision, summary) VALUES (?, ?, ?, ?, ?)",
            (goal_id, mission_id, now, decision, summary.strip()[:MAX_BODY_CHARS]))
        self._db.commit()
        return dict(zip(CHECK_COLUMNS, (cursor.lastrowid, goal_id, mission_id, now, decision, summary)))

    def checks(self, goal_id: str, limit: int = 20) -> list[dict]:
        rows = self._db.execute(f"SELECT {', '.join(CHECK_COLUMNS)} FROM goal_checks WHERE goal_id = ? "
                                "ORDER BY id DESC LIMIT ?", (goal_id, limit))
        return [dict(zip(CHECK_COLUMNS, row)) for row in rows]

    def checks_today(self, now: float | None = None) -> int:
        since = start_of_day(now or time.time())
        return self._db.execute("SELECT COUNT(*) FROM goal_checks WHERE at >= ?", (since,)).fetchone()[0]

    def kept_notes(self, goal_id: str, limit: int = 5) -> list[str]:
        """What earlier checks kept for later, so the next one can tell what changed."""
        rows = self._db.execute("SELECT summary FROM goal_checks WHERE goal_id = ? AND decision IN (?, ?) "
                                "AND summary != '' ORDER BY id DESC LIMIT ?", (goal_id, LATER, NOTIFY, limit))
        return [summary for (summary,) in rows]

    # MARK: Ideas

    def get(self, idea_id: str) -> Idea | None:
        row = self._db.execute(f"SELECT {', '.join(IDEA_COLUMNS)} FROM ideas WHERE id = ?", (idea_id,)).fetchone()
        return Idea(*row) if row else None

    def list(self, status: str | None = None, goal_id: str | None = None) -> list[Idea]:
        query, clauses, params = f"SELECT {', '.join(IDEA_COLUMNS)} FROM ideas", [], []
        if status:
            clauses.append("status = ?")
            params.append(status)
        else:
            clauses.append("status != ?")
            params.append(DISMISSED)
        if goal_id:
            clauses.append("goal_id = ?")
            params.append(goal_id)
        query += " WHERE " + " AND ".join(clauses) + " ORDER BY created_at DESC LIMIT 200"
        return [Idea(*row) for row in self._db.execute(query, params)]

    def ideas_today(self, now: float | None = None) -> int:
        since = start_of_day(now or time.time())
        return self._db.execute("SELECT COUNT(*) FROM ideas WHERE created_at >= ?", (since,)).fetchone()[0]

    def unseen(self) -> int:
        return self._db.execute("SELECT COUNT(*) FROM ideas WHERE status = ?", (NEW,)).fetchone()[0]

    def find_similar(self, goal_id: str, title: str, since: float) -> Idea | None:
        """A dismissed idea of this goal, or a recent one, saying the same thing."""
        rows = self._db.execute(f"SELECT {', '.join(IDEA_COLUMNS)} FROM ideas WHERE goal_id = ? "
                                "AND (status = ? OR created_at >= ?)", (goal_id, DISMISSED, since))
        for row in rows:
            if similarity(row[3], title) >= DUPLICATE_SIMILARITY:
                return Idea(*row)
        return None

    def dismissed_titles(self, goal_id: str, limit: int = 10) -> list[str]:
        rows = self._db.execute("SELECT title FROM ideas WHERE goal_id = ? AND status = ? "
                                "ORDER BY updated_at DESC LIMIT ?", (goal_id, DISMISSED, limit))
        return [title for (title,) in rows]

    def add(self, goal_id: str, goal_title: str, title: str, body: str = "", action: str = "",
            importance: int = 3, mission_id: str = "", action_detail: str = "") -> Idea:
        now = time.time()
        action = " ".join(action.split())[:MAX_ACTION_CHARS]
        idea = Idea(id=secrets.token_hex(6), goal_id=goal_id, goal_title=goal_title,
                    title=" ".join(title.split())[:MAX_TITLE_CHARS], body=body.strip()[:MAX_BODY_CHARS],
                    action=action, importance=max(1, min(5, importance)),
                    mission_id=mission_id, created_at=now, updated_at=now,
                    action_detail=action_detail.strip()[:MAX_DETAIL_CHARS] if action else "")
        self._store(idea)
        return idea

    def update(self, idea_id: str, **changes) -> Idea:
        idea = self.get(idea_id)
        if not idea:
            raise KeyError(idea_id)
        for key, value in changes.items():
            setattr(idea, key, value)
        idea.updated_at = time.time()
        self._store(idea)
        return idea

    def mark_seen(self) -> int:
        cursor = self._db.execute("UPDATE ideas SET status = ?, updated_at = ? WHERE status = ?",
                                  (SEEN, time.time(), NEW))
        self._db.commit()
        return cursor.rowcount

    def delete(self, idea_id: str) -> None:
        self._db.execute("DELETE FROM ideas WHERE id = ?", (idea_id,))
        self._db.commit()

    def _store(self, idea: Idea) -> None:
        self._db.execute(
            f"INSERT OR REPLACE INTO ideas ({', '.join(IDEA_COLUMNS)}) VALUES ({', '.join('?' * len(IDEA_COLUMNS))})",
            tuple(idea.public().values()),
        )
        self._db.commit()
