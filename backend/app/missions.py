"""Missions: one assistant reply generated on the VPS, independent of the iPhone's connection.

A mission keeps running when the app is closed or offline. The app can reconnect at any
time and ask for the text from a given offset, so nothing is lost. Progress is saved to
SQLite, so a finished reply survives a backend restart; a mission that was running when
the backend stopped is marked "interrupted".

The emergency stop cancels every running mission and refuses new ones until it is lifted,
so no request reaches Hermes (and Scaleway) in the meantime. It survives restarts.
"""

import asyncio
import json
import logging
import secrets
import sqlite3
import time
from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass, field
from pathlib import Path

log = logging.getLogger("marcel.missions")

RUNNING, DONE, FAILED, STOPPED, INTERRUPTED = "running", "done", "failed", "stopped", "interrupted"
# Running missions are saved this often, so a crash loses at most a few seconds of text.
SAVE_INTERVAL = 2.0
# Finished missions stay in memory this long for fast reconnects, then are read from SQLite.
KEEP_IN_MEMORY = 3600
# A heartbeat comment keeps proxies (Tailscale Serve) from closing an idle stream.
HEARTBEAT = 15.0
RESTART_ERROR = "Le serveur a redémarré pendant la mission."
EMERGENCY_ERROR = "Arrêt d'urgence : la mission a été coupée."

class MissionError(Exception):
    """A failure whose message is meant for the user (shown instead of the generic one)."""


# A mission source yields text, or an action dict {"id", "name", "detail", "status"}
# whenever the agent starts or finishes a step (a tool call, a command…).
Source = Callable[[], AsyncIterator[str | dict]]


@dataclass
class Mission:
    id: str
    conversation_id: str
    status: str = RUNNING
    text: str = ""
    error: str | None = None
    created_at: float = field(default_factory=time.time)
    finished_at: float | None = None
    model: str | None = None
    title: str = ""
    actions: list[dict] = field(default_factory=list)
    task: asyncio.Task | None = field(default=None, repr=False)
    actions_version: int = field(default=0, repr=False)
    _changed: asyncio.Event = field(default_factory=asyncio.Event, repr=False)

    def public(self) -> dict:
        """What the app sees. `length` counts Unicode code points, the unit of `offset`."""
        return {
            "id": self.id,
            "conversation_id": self.conversation_id,
            "status": self.status,
            "length": len(self.text),
            "error": self.error,
            "created_at": self.created_at,
            "finished_at": self.finished_at,
            "model": self.model,
            "title": self.title,
            "actions": self.actions,
        }

    def notify(self) -> None:
        changed, self._changed = self._changed, asyncio.Event()
        changed.set()

    def record(self, action: dict) -> None:
        """Adds an action, or updates the one with the same id."""
        for index, existing in enumerate(self.actions):
            if existing["id"] == action["id"]:
                self.actions[index] = existing | action
                break
        else:
            self.actions.append(action)
        self.actions_version += 1


def valid_id(mission_id: str) -> bool:
    return len(mission_id) == 32 and all(c in "0123456789abcdef" for c in mission_id)


COLUMNS = "id, conversation_id, status, text, error, created_at, finished_at, model, title, actions"


class MissionStore:
    def __init__(self, db_path: Path, max_running: int = 4):
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self.max_running = max_running
        self._shutting_down = False
        self._missions: dict[str, Mission] = {}
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        self._db.execute(
            """CREATE TABLE IF NOT EXISTS missions (
                id TEXT PRIMARY KEY,
                conversation_id TEXT NOT NULL,
                status TEXT NOT NULL,
                text TEXT NOT NULL DEFAULT '',
                error TEXT,
                created_at REAL NOT NULL,
                finished_at REAL
            )"""
        )
        # Columns added after the first version.
        existing = {row[1] for row in self._db.execute("PRAGMA table_info(missions)")}
        for column, kind in (("model", "TEXT"), ("title", "TEXT NOT NULL DEFAULT ''"),
                             ("actions", "TEXT NOT NULL DEFAULT '[]'")):
            if column not in existing:
                self._db.execute(f"ALTER TABLE missions ADD COLUMN {column} {kind}")
        self._db.execute("CREATE INDEX IF NOT EXISTS missions_conversation ON missions (conversation_id)")
        self._db.execute("CREATE TABLE IF NOT EXISTS flags (name TEXT PRIMARY KEY, value TEXT NOT NULL)")
        # Whatever was running when the backend last stopped can't be resumed.
        self._db.execute(
            "UPDATE missions SET status = ?, error = ?, finished_at = ? WHERE status = ?",
            (INTERRUPTED, RESTART_ERROR, time.time(), RUNNING),
        )
        self._db.commit()

    # MARK: Emergency stop

    @property
    def emergency(self) -> bool:
        row = self._db.execute("SELECT value FROM flags WHERE name = 'emergency'").fetchone()
        return bool(row and row[0] == "1")

    async def emergency_stop(self) -> int:
        """Cancels every running mission and blocks new ones. Returns how many were cut."""
        self._db.execute("INSERT OR REPLACE INTO flags (name, value) VALUES ('emergency', '1')")
        self._db.commit()
        running = [m for m in self._missions.values() if m.status == RUNNING and m.task]
        for mission in running:
            mission.error = EMERGENCY_ERROR
            mission.task.cancel()
        await asyncio.gather(*(m.task for m in running), return_exceptions=True)
        return len(running)

    def emergency_resume(self) -> None:
        self._db.execute("DELETE FROM flags WHERE name = 'emergency'")
        self._db.commit()

    # MARK: Lifecycle

    def running_count(self) -> int:
        return sum(1 for m in self._missions.values() if m.status == RUNNING)

    def start(self, conversation_id: str, source: Source, model: str | None = None, title: str = "") -> Mission:
        self._prune()
        mission = Mission(id=secrets.token_hex(16), conversation_id=conversation_id, model=model, title=title[:120])
        self._missions[mission.id] = mission
        self._save(mission)
        mission.task = asyncio.create_task(self._run(mission, source))
        return mission

    async def _run(self, mission: Mission, source: Source) -> None:
        last_save = time.monotonic()
        try:
            async for item in source():
                if isinstance(item, dict):
                    mission.record(item)
                else:
                    mission.text += item
                mission.notify()
                if time.monotonic() - last_save > SAVE_INTERVAL:
                    self._save(mission)
                    last_save = time.monotonic()
            mission.status = DONE
        except asyncio.CancelledError:
            if self._shutting_down:
                mission.status, mission.error = INTERRUPTED, RESTART_ERROR
            elif mission.error == EMERGENCY_ERROR:
                mission.status = INTERRUPTED
            else:
                mission.status = STOPPED
        except Exception as error:
            log.exception("mission %s failed", mission.id)
            mission.status = FAILED
            mission.error = str(error) if isinstance(error, MissionError) else "Hermes n'a pas pu répondre."
        finally:
            # Steps still marked as running didn't finish.
            for action in mission.actions:
                if action.get("status") == "running":
                    mission.record({"id": action["id"], "status": "done" if mission.status == DONE else "cancelled"})
            mission.finished_at = time.time()
            self._save(mission)
            mission.notify()

    def cancel(self, mission: Mission) -> None:
        if mission.status == RUNNING and mission.task:
            mission.task.cancel()

    async def shutdown(self) -> None:
        self._shutting_down = True
        tasks = [m.task for m in self._missions.values() if m.task and not m.task.done()]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

    # MARK: Reading

    def get(self, mission_id: str) -> Mission | None:
        if mission := self._missions.get(mission_id):
            return mission
        row = self._db.execute(f"SELECT {COLUMNS} FROM missions WHERE id = ?", (mission_id,)).fetchone()
        if not row:
            return None
        *values, actions = row
        return Mission(*values, actions=json.loads(actions or "[]"))

    def list(self, conversation_id: str | None = None, active_only: bool = False) -> list[Mission]:
        query = "SELECT id FROM missions"
        clauses, params = [], []
        if conversation_id:
            clauses.append("conversation_id = ?")
            params.append(conversation_id)
        if active_only:
            clauses.append("status = ?")
            params.append(RUNNING)
        if clauses:
            query += " WHERE " + " AND ".join(clauses)
        query += " ORDER BY created_at DESC LIMIT 100"
        ids = [row[0] for row in self._db.execute(query, params)]
        return [m for i in ids if (m := self.get(i))]

    def finished_since(self, since: float, limit: int = 2000) -> list[Mission]:
        """Completed replies since then, newest first (for searching past answers)."""
        rows = self._db.execute(f"SELECT {COLUMNS} FROM missions WHERE status = ? AND created_at >= ? "
                                "ORDER BY created_at DESC LIMIT ?", (DONE, since, limit))
        return [Mission(*values, actions=json.loads(actions or "[]")) for *values, actions in rows]

    async def follow(self, mission: Mission, offset: int) -> AsyncIterator[dict | None]:
        """Text from `offset` onwards, then live deltas until the mission ends.

        The full list of actions is sent first and again whenever it changes.
        Yields event dicts, or None as a heartbeat while nothing happens.
        """
        offset = max(0, min(offset, len(mission.text)))
        sent_actions = -1 if mission.actions else 0
        while True:
            # Take the waiter before reading, so a change between the two isn't missed.
            changed = mission._changed
            if mission.actions_version != sent_actions:
                sent_actions = mission.actions_version
                yield {"type": "actions", "actions": mission.actions}
            if len(mission.text) > offset:
                yield {"type": "delta", "text": mission.text[offset:]}
                offset = len(mission.text)
            if mission.status != RUNNING:
                yield end_event(mission)
                return
            try:
                await asyncio.wait_for(changed.wait(), HEARTBEAT)
            except TimeoutError:
                yield None

    # MARK: Storage

    def _save(self, mission: Mission) -> None:
        self._db.execute(
            f"""INSERT INTO missions ({COLUMNS}) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT (id) DO UPDATE SET status = excluded.status, text = excluded.text,
                   error = excluded.error, finished_at = excluded.finished_at, actions = excluded.actions""",
            (mission.id, mission.conversation_id, mission.status, mission.text, mission.error,
             mission.created_at, mission.finished_at, mission.model, mission.title,
             json.dumps(mission.actions, ensure_ascii=False)),
        )
        self._db.commit()

    def _prune(self) -> None:
        cutoff = time.time() - KEEP_IN_MEMORY
        for mission_id, mission in list(self._missions.items()):
            if mission.status != RUNNING and (mission.finished_at or 0) < cutoff:
                del self._missions[mission_id]


def end_event(mission: Mission) -> dict:
    if mission.status == DONE:
        return {"type": "done"}
    if mission.status == STOPPED:
        return {"type": "stopped"}
    return {"type": "error", "message": mission.error or "La mission a échoué."}
