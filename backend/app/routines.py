"""Routines: a task the user wants done at a fixed time ("every Monday at 8, the week ahead").

Unlike a goal, a routine isn't followed over time: at its hour, Marcel runs its instruction once
and the reply lands in the routine's own conversation on the iPhone, where the user can answer.
A routine runs while the user isn't there, so it only reads and prepares: it goes to the Hermes
without tools that act (or to the model alone when e-mails are involved), never to the full one.
"""

from __future__ import annotations

import secrets
import sqlite3
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

ACTIVE, PAUSED = "active", "paused"
RUNNING, DONE, FAILED = "running", "done", "failed"
WEEKDAYS = ("lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche")
# A run missed while the server was down still happens if it comes back within this delay;
# later, it waits for the next slot (a "good morning" at 4 pm is no use).
GRACE = 3 * 3600
MAX_TITLE_CHARS, MAX_PROMPT_CHARS = 80, 1000
# Events a routine can wait for instead of an hour (read by the rma robot).
TRIGGERS = {"offre": "À chaque nouvelle offre", "planning": "Quand le planning change",
            "email": "À chaque nouvel e-mail"}
# "email:sender" waits for e-mails from that sender only (an address or a part of it).
EMAIL_FROM = "email:"


def valid_trigger(trigger: str) -> bool:
    if trigger.startswith(EMAIL_FROM):
        sender = trigger[len(EMAIL_FROM):]
        return 2 <= len(sender) <= 120 and not any(c.isspace() for c in sender)
    return trigger in TRIGGERS


def describe_trigger(trigger: str) -> str:
    if trigger.startswith(EMAIL_FROM):
        return f"À chaque e-mail de {trigger[len(EMAIL_FROM):]}"
    return TRIGGERS.get(trigger, "")

COLUMNS = ("id", "title", "prompt", "days", "at", "status", "conversation_id", "created_at", "updated_at",
           "last_run_at", "assistant", "once", "trigger")
RUN_COLUMNS = ("id", "routine_id", "mission_id", "at", "status", "error", "delivered")


@dataclass
class Routine:
    id: str
    title: str
    prompt: str
    # Weekdays it runs on, 0 = Monday ("0,2,4"); empty = every day.
    days: str = ""
    # Local time, "08:00".
    at: str = "08:00"
    status: str = ACTIVE
    # The iPhone conversation the replies go to (a UUID, like the app's own conversations).
    conversation_id: str = ""
    created_at: float = 0.0
    updated_at: float = 0.0
    last_run_at: float | None = None
    # Set when an assistant made it in its conversation: it comes back there, as that assistant
    # (a "relance"), instead of in a conversation of its own.
    assistant: str = ""
    # A one-off relance ("remind me Tuesday at 9"): paused after its first run.
    once: bool = False
    # An event from TRIGGERS instead of the hour; empty for a routine at a fixed time.
    trigger: str = ""

    def __post_init__(self):
        self.once = bool(self.once)

    def public(self) -> dict:
        return {c: getattr(self, c) for c in COLUMNS} | {"schedule": self.schedule}

    @property
    def schedule(self) -> str:
        return describe_trigger(self.trigger) or describe(self.days, self.at)

    @property
    def weekdays(self) -> list[int]:
        return parse_days(self.days)


def parse_days(days: str) -> list[int]:
    return sorted({int(d) for d in days.split(",") if d.strip().isdigit() and 0 <= int(d) <= 6})


def days_from_names(names: list[str]) -> str:
    """["lundi", "jeudi"] (or "tous", "semaine", "week-end") → "0,3"."""
    picked: set[int] = set()
    for raw in names:
        # "lundis" → "lundi", "tous les jours" → "tous les jour".
        name = str(raw).strip().lower().removesuffix("s")
        if name in ("", "tou", "tous les jour", "chaque jour", "jour"):
            return ""
        if name in ("semaine", "en semaine"):
            picked |= {0, 1, 2, 3, 4}
        elif name in ("week-end", "weekend"):
            picked |= {5, 6}
        elif name in WEEKDAYS:
            picked.add(WEEKDAYS.index(name))
        elif name.isdigit() and 0 <= int(name) <= 6:
            picked.add(int(name))
        else:
            raise ValueError(f"jour inconnu : {name}")
    return "" if len(picked) == 7 else ",".join(str(d) for d in sorted(picked))


def valid_time(at: str) -> str:
    """"8h", "8:00", "08h30" → "08:00", "08:30"."""
    raw = str(at).strip().lower().replace("h", ":")
    hour, _, minute = raw.partition(":")
    try:
        hour_value, minute_value = int(hour), int(minute or 0)
    except ValueError:
        raise ValueError(f"heure illisible : {at}") from None
    if not (0 <= hour_value <= 23 and 0 <= minute_value <= 59):
        raise ValueError(f"heure impossible : {at}")
    return f"{hour_value:02d}:{minute_value:02d}"


def describe(days: str, at: str) -> str:
    """"Chaque lundi à 08:00", "Chaque jour à 07:30", "En semaine à 18:00"."""
    weekdays = parse_days(days)
    if not weekdays:
        when = "Chaque jour"
    elif weekdays == [0, 1, 2, 3, 4]:
        when = "En semaine"
    elif weekdays == [5, 6]:
        when = "Le week-end"
    else:
        names = [WEEKDAYS[d] for d in weekdays]
        when = "Chaque " + (names[0] if len(names) == 1 else ", ".join(names[:-1]) + " et " + names[-1])
    hour, _, minute = at.partition(":")
    return f"{when} à {int(hour)} h" + (f" {minute}" if minute not in ("", "00") else "")


def last_slot(routine: Routine, now: float, tz: ZoneInfo | None) -> float | None:
    """The latest time the routine should have run at, up to now (within the last week)."""
    hour, minute = (int(part) for part in routine.at.split(":"))
    today = datetime.fromtimestamp(now, tz).date()
    for back in range(8):
        day = today - timedelta(days=back)
        if routine.weekdays and day.weekday() not in routine.weekdays:
            continue
        slot = datetime(day.year, day.month, day.day, hour, minute, tzinfo=tz).timestamp()
        if slot <= now:
            return slot
    return None


def is_due(routine: Routine, now: float, tz: ZoneInfo | None) -> bool:
    if routine.status != ACTIVE or routine.trigger:
        return False
    slot = last_slot(routine, now, tz)
    if slot is None or now - slot > GRACE:
        return False
    # A routine created (or run by hand) after the slot waits for the next one.
    return slot > max(routine.last_run_at or 0, routine.created_at)


class RoutineStore:
    def __init__(self, db_path: Path, tz: ZoneInfo | None):
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self.tz = tz
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        self._db.executescript(
            """CREATE TABLE IF NOT EXISTS routines (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                prompt TEXT NOT NULL,
                days TEXT NOT NULL DEFAULT '',
                at TEXT NOT NULL DEFAULT '08:00',
                status TEXT NOT NULL DEFAULT 'active',
                conversation_id TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                last_run_at REAL,
                assistant TEXT NOT NULL DEFAULT '',
                once INTEGER NOT NULL DEFAULT 0,
                trigger TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS routine_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                routine_id TEXT NOT NULL,
                mission_id TEXT NOT NULL DEFAULT '',
                at REAL NOT NULL,
                status TEXT NOT NULL,
                error TEXT NOT NULL DEFAULT '',
                delivered INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS routine_runs_routine ON routine_runs (routine_id);"""
        )
        # Databases from before relances.
        existing = {row[1] for row in self._db.execute("PRAGMA table_info(routines)")}
        if "assistant" not in existing:
            self._db.execute("ALTER TABLE routines ADD COLUMN assistant TEXT NOT NULL DEFAULT ''")
        if "once" not in existing:
            self._db.execute("ALTER TABLE routines ADD COLUMN once INTEGER NOT NULL DEFAULT 0")
        if "trigger" not in existing:
            self._db.execute("ALTER TABLE routines ADD COLUMN trigger TEXT NOT NULL DEFAULT ''")
        self._db.commit()

    # MARK: Routines

    def get(self, routine_id: str) -> Routine | None:
        row = self._db.execute(f"SELECT {', '.join(COLUMNS)} FROM routines WHERE id = ?", (routine_id,)).fetchone()
        return Routine(*row) if row else None

    def list(self, status: str | None = None) -> list[Routine]:
        query, params = f"SELECT {', '.join(COLUMNS)} FROM routines", ()
        if status:
            query, params = query + " WHERE status = ?", (status,)
        return [Routine(*row) for row in self._db.execute(query + " ORDER BY at, created_at", params)]

    def add(self, title: str, prompt: str, days: str = "", at: str = "08:00", assistant: str = "",
            conversation_id: str = "", once: bool = False, trigger: str = "") -> Routine:
        if trigger and not valid_trigger(trigger):
            raise ValueError(f"déclencheur inconnu : {trigger}")
        now = time.time()
        routine = Routine(id=secrets.token_hex(6), title=" ".join(title.split())[:MAX_TITLE_CHARS],
                          prompt=prompt.strip()[:MAX_PROMPT_CHARS], days=",".join(map(str, parse_days(days))),
                          at=valid_time(at), conversation_id=conversation_id or str(uuid.uuid4()).upper(),
                          created_at=now, updated_at=now, assistant=assistant, once=once, trigger=trigger)
        if len(routine.title) < 2 or len(routine.prompt) < 3:
            raise ValueError("titre ou consigne trop court")
        self._store(routine)
        return routine

    def update(self, routine_id: str, **changes) -> Routine:
        routine = self.get(routine_id)
        if not routine:
            raise KeyError(routine_id)
        for key, value in changes.items():
            setattr(routine, key, value)
        routine.title = " ".join(routine.title.split())[:MAX_TITLE_CHARS]
        routine.prompt = routine.prompt.strip()[:MAX_PROMPT_CHARS]
        routine.days = ",".join(map(str, parse_days(routine.days)))
        routine.at = valid_time(routine.at)
        routine.updated_at = time.time()
        self._store(routine)
        return routine

    def mark_run(self, routine_id: str, at: float) -> None:
        self._db.execute("UPDATE routines SET last_run_at = ? WHERE id = ?", (at, routine_id))
        self._db.commit()

    def delete(self, routine_id: str) -> None:
        self._db.execute("DELETE FROM routine_runs WHERE routine_id = ?", (routine_id,))
        self._db.execute("DELETE FROM routines WHERE id = ?", (routine_id,))
        self._db.commit()

    def waiting_for(self, event: str) -> list[Routine]:
        return [r for r in self.list(ACTIVE) if r.trigger == event
                or (event == "email" and r.trigger.startswith(EMAIL_FROM))]

    def due(self, now: float) -> list[Routine]:
        return [r for r in self.list(ACTIVE) if is_due(r, now, self.tz)]

    def context(self) -> str:
        active = self.list(ACTIVE)
        if not active:
            return ""
        return "Routines de l'utilisateur (lancées seules à heure fixe) :\n" + "\n".join(
            f"- {r.title} : {r.schedule}" for r in active)

    # MARK: Runs

    def start_run(self, routine_id: str, mission_id: str) -> int:
        cursor = self._db.execute("INSERT INTO routine_runs (routine_id, mission_id, at, status) VALUES (?, ?, ?, ?)",
                                  (routine_id, mission_id, time.time(), RUNNING))
        self._db.commit()
        return cursor.lastrowid

    def finish_run(self, run_id: int, status: str, error: str = "") -> None:
        self._db.execute("UPDATE routine_runs SET status = ?, error = ? WHERE id = ?", (status, error[:300], run_id))
        self._db.commit()

    def runs(self, routine_id: str, limit: int = 20) -> list[dict]:
        rows = self._db.execute(f"SELECT {', '.join(RUN_COLUMNS)} FROM routine_runs WHERE routine_id = ? "
                                "ORDER BY id DESC LIMIT ?", (routine_id, limit))
        return [self._run(row) for row in rows]

    def pending(self) -> list[dict]:
        """Finished runs the iPhone hasn't put in their conversation yet, oldest first."""
        rows = self._db.execute(f"SELECT {', '.join(RUN_COLUMNS)} FROM routine_runs WHERE delivered = 0 "
                                "AND status != ? ORDER BY id LIMIT 20", (RUNNING,))
        return [self._run(row) for row in rows]

    def mark_delivered(self, run_id: int) -> bool:
        cursor = self._db.execute("UPDATE routine_runs SET delivered = 1 WHERE id = ?", (run_id,))
        self._db.commit()
        return cursor.rowcount > 0

    def runs_today(self, now: float | None = None) -> int:
        t = time.localtime(now or time.time())
        since = time.mktime((t.tm_year, t.tm_mon, t.tm_mday, 0, 0, 0, 0, 0, -1))
        return self._db.execute("SELECT COUNT(*) FROM routine_runs WHERE at >= ?", (since,)).fetchone()[0]

    @staticmethod
    def _run(row) -> dict:
        run = dict(zip(RUN_COLUMNS, row))
        run["delivered"] = bool(run["delivered"])
        return run

    def _store(self, routine: Routine) -> None:
        self._db.execute(
            f"INSERT OR REPLACE INTO routines ({', '.join(COLUMNS)}) VALUES ({', '.join('?' * len(COLUMNS))})",
            tuple(getattr(routine, c) for c in COLUMNS),
        )
        self._db.commit()
