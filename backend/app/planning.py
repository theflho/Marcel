"""The user's work planning (RMA missions), read by the rma robot and kept here.

Marcel knows it (it goes with every mission, the next 7 days) and the app schedules a
reminder 5 minutes before each start and end. Read only: nothing here ever clocks in.
"""

import hashlib
import sqlite3
import time
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

COLUMNS = ("id", "store", "kind", "client", "start_at", "end_at", "updated_at")
# Past missions are kept a while for "how many hours this month".
KEEP_PAST = 45 * 86_400


class PlanningStore:
    def __init__(self, db_path: Path, tz: ZoneInfo | None):
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self.tz = tz
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        self._db.execute(
            """CREATE TABLE IF NOT EXISTS planning (
                id TEXT PRIMARY KEY,
                store TEXT NOT NULL,
                kind TEXT NOT NULL DEFAULT '',
                client TEXT NOT NULL DEFAULT '',
                start_at REAL NOT NULL,
                end_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )"""
        )
        self._db.commit()

    def _timestamp(self, date: str, clock: str, next_day: bool = False) -> float:
        """"26/10/2026", "20:00" in the user's time zone → seconds since 1970."""
        moment = datetime.strptime(f"{date} {clock}", "%d/%m/%Y %H:%M") + timedelta(days=1 if next_day else 0)
        return moment.replace(tzinfo=self.tz).timestamp()

    def replace(self, missions: list[dict]) -> int:
        """Stores what the robot read; upcoming missions it no longer sees were cancelled."""
        now = time.time()
        rows = []
        for mission in missions:
            try:
                start = self._timestamp(mission["date"], mission["start"])
                end = self._timestamp(mission["date"], mission["end"])
            except (KeyError, ValueError):
                continue
            if end <= start:  # a night mission ends the next day (by the calendar, not 24 h: DST)
                end = self._timestamp(mission["date"], mission["end"], next_day=True)
            store = " ".join(str(mission.get("store", "")).split())[:120]
            key = hashlib.sha256(f"{mission['date']}|{mission['start']}|{store}".encode()).hexdigest()[:16]
            rows.append((key, store, str(mission.get("kind", ""))[:120], str(mission.get("client", ""))[:120],
                         start, end, now))
        self._db.execute("DELETE FROM planning WHERE start_at >= ? OR end_at < ?", (now, now - KEEP_PAST))
        self._db.executemany(f"INSERT OR REPLACE INTO planning ({', '.join(COLUMNS)}) VALUES (?, ?, ?, ?, ?, ?, ?)", rows)
        self._db.commit()
        return len(rows)

    def list(self, since: float, until: float) -> list[dict]:
        rows = self._db.execute(f"SELECT {', '.join(COLUMNS)} FROM planning WHERE end_at >= ? AND start_at <= ? "
                                "ORDER BY start_at", (since, until))
        return [dict(zip(COLUMNS, row)) for row in rows]

    def context(self, days: int = 7) -> str:
        """The coming missions, for the note sent with every mission."""
        now = time.time()
        missions = self.list(now - 3600, now + days * 86_400)
        if not missions:
            return ""
        lines = [f"Planning de travail de l'utilisateur (missions RMA, {days} prochains jours) :"]
        for m in missions:
            start = datetime.fromtimestamp(m["start_at"], self.tz)
            end = datetime.fromtimestamp(m["end_at"], self.tz)
            lines.append(f"- {start:%d/%m %H:%M}-{end:%H:%M} · {m['store']} · {m['kind']} · {m['client']}")
        lines.append("Le pointage se fait par l'utilisateur, sur place, dans le portail : tu ne pointes jamais.")
        return "\n".join(lines)
