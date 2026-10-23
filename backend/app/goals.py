"""Goals: what the user still wants to accomplish, so Marcel can follow it over time.

Marcel only proposes a goal (spotted in a conversation); it is followed once the user accepts.
A goal the user turned down is kept as "dismissed", so the same idea isn't proposed again.
Active goals are sent with every mission. The cadence is when Marcel checks on a goal by
itself (see proactive.py); `last_run_at` is the last of those checks.
"""

import secrets
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path

from .memory import similarity

PROPOSED, ACTIVE, PAUSED, DONE, DISMISSED = "proposed", "active", "paused", "done", "dismissed"
STATUSES = (PROPOSED, ACTIVE, PAUSED, DONE, DISMISSED)
CADENCES = ("hourly", "daily", "weekly", "manual")
# A proposal this close to an existing goal (even a dismissed one) is dropped.
DUPLICATE_SIMILARITY = 0.6
MAX_TITLE_CHARS, MAX_DETAIL_CHARS = 120, 500

COLUMNS = ("id", "title", "detail", "status", "cadence", "conversation_id", "created_at", "updated_at",
           "last_run_at")


@dataclass
class Goal:
    id: str
    title: str
    detail: str = ""
    status: str = PROPOSED
    cadence: str = "weekly"
    conversation_id: str = ""
    created_at: float = 0.0
    updated_at: float = 0.0
    last_run_at: float | None = None

    def public(self) -> dict:
        return {c: getattr(self, c) for c in COLUMNS}


class GoalStore:
    def __init__(self, db_path: Path):
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        self._db.execute(
            """CREATE TABLE IF NOT EXISTS goals (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                detail TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'proposed',
                cadence TEXT NOT NULL DEFAULT 'weekly',
                conversation_id TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                last_run_at REAL
            )"""
        )
        self._db.commit()

    def get(self, goal_id: str) -> Goal | None:
        row = self._db.execute(f"SELECT {', '.join(COLUMNS)} FROM goals WHERE id = ?", (goal_id,)).fetchone()
        return Goal(*row) if row else None

    def list(self, status: str | None = None, conversation_id: str | None = None) -> list[Goal]:
        query, clauses, params = f"SELECT {', '.join(COLUMNS)} FROM goals", [], []
        if status:
            clauses.append("status = ?")
            params.append(status)
        else:
            clauses.append("status != ?")
            params.append(DISMISSED)
        if conversation_id:
            clauses.append("conversation_id = ?")
            params.append(conversation_id)
        query += " WHERE " + " AND ".join(clauses) + " ORDER BY updated_at DESC"
        return [Goal(*row) for row in self._db.execute(query, params)]

    def find_similar(self, title: str) -> Goal | None:
        for row in self._db.execute(f"SELECT {', '.join(COLUMNS)} FROM goals"):
            if similarity(row[1], title) >= DUPLICATE_SIMILARITY:
                return Goal(*row)
        return None

    def propose(self, title: str, detail: str = "", cadence: str = "weekly", conversation_id: str = "") -> Goal | None:
        """Adds a proposal, unless a goal like it already exists or was turned down."""
        title = " ".join(title.split())[:MAX_TITLE_CHARS]
        if len(title) < 3 or self.find_similar(title):
            return None
        return self.add(title, detail, cadence, conversation_id, status=PROPOSED)

    def add(self, title: str, detail: str = "", cadence: str = "weekly", conversation_id: str = "",
            status: str = ACTIVE) -> Goal:
        now = time.time()
        goal = Goal(id=secrets.token_hex(6), title=" ".join(title.split())[:MAX_TITLE_CHARS],
                    detail=detail.strip()[:MAX_DETAIL_CHARS], status=status,
                    cadence=cadence if cadence in CADENCES else "weekly",
                    conversation_id=conversation_id, created_at=now, updated_at=now)
        self._store(goal)
        return goal

    def update(self, goal_id: str, **changes) -> Goal:
        goal = self.get(goal_id)
        if not goal:
            raise KeyError(goal_id)
        for key, value in changes.items():
            setattr(goal, key, value)
        goal.title = " ".join(goal.title.split())[:MAX_TITLE_CHARS]
        goal.detail = goal.detail.strip()[:MAX_DETAIL_CHARS]
        goal.updated_at = time.time()
        self._store(goal)
        return goal

    def mark_run(self, goal_id: str, at: float) -> None:
        """Records a check without touching `updated_at`, so the list keeps its order."""
        self._db.execute("UPDATE goals SET last_run_at = ? WHERE id = ?", (at, goal_id))
        self._db.commit()

    def delete(self, goal_id: str) -> None:
        self._db.execute("DELETE FROM goals WHERE id = ?", (goal_id,))
        self._db.commit()

    def context(self) -> str:
        """Lines added to the note sent with every mission."""
        active = self.list(ACTIVE)
        if not active:
            return ""
        lines = ["Objectifs que l'utilisateur t'a demandé de suivre :"]
        lines += [f"- {g.title}" + (f" ({g.detail})" if g.detail else "") for g in active]
        return "\n".join(lines)

    def _store(self, goal: Goal) -> None:
        self._db.execute(
            f"INSERT OR REPLACE INTO goals ({', '.join(COLUMNS)}) VALUES ({', '.join('?' * len(COLUMNS))})",
            tuple(goal.public().values()),
        )
        self._db.commit()
