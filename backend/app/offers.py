"""Recruitment offers from the RMA portal ("Recrutements › Attente de réponse"), read by the rma
robot. Read only: accepting or declining an offer stays the user's own act, in the portal.
"""

from __future__ import annotations

import hashlib
import sqlite3
import time
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

COLUMNS = ("id", "store", "day", "kind", "client", "agency", "first_seen", "last_seen", "status")
OPEN, GONE = "open", "gone"
# Offers no longer shown (answered, withdrawn) are kept a while, then forgotten.
KEEP_GONE = 30 * 86_400
MONTHS = {"janv": 1, "févr": 2, "fevr": 2, "mars": 3, "avr": 4, "mai": 5, "juin": 6, "juil": 7, "août": 8,
          "aout": 8, "sept": 9, "oct": 10, "nov": 11, "déc": 12, "dec": 12}


def parse_day(text: str, tz: ZoneInfo | None) -> float | None:
    """ "19 oct. 2026" → midnight of that day (seconds since 1970), or None."""
    parts = text.replace(".", "").split()
    if len(parts) != 3:
        return None
    day, month, year = parts
    number = MONTHS.get(month.lower()[:5]) or MONTHS.get(month.lower()[:4])
    try:
        return datetime(int(year), number, int(day), tzinfo=tz).timestamp() if number else None
    except ValueError:
        return None


class OfferStore:
    def __init__(self, db_path: Path, tz: ZoneInfo | None):
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self.tz = tz
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        self._db.execute(
            """CREATE TABLE IF NOT EXISTS offers (
                id TEXT PRIMARY KEY,
                store TEXT NOT NULL,
                day REAL NOT NULL,
                kind TEXT NOT NULL DEFAULT '',
                client TEXT NOT NULL DEFAULT '',
                agency TEXT NOT NULL DEFAULT '',
                first_seen REAL NOT NULL,
                last_seen REAL NOT NULL,
                status TEXT NOT NULL DEFAULT 'open'
            )"""
        )
        self._db.commit()

    def replace(self, offers: list[dict]) -> int:
        """What the robot sees now; open offers it no longer sees were answered or withdrawn."""
        now = time.time()
        seen = []
        for offer in offers:
            day = parse_day(str(offer.get("date", "")), self.tz)
            store = " ".join(str(offer.get("store", "")).split())[:120]
            if day is None or not store:
                continue
            kind = " ".join(str(offer.get("kind", "")).split())[:120]
            key = hashlib.sha256(f"{day}|{store}|{kind}".encode()).hexdigest()[:16]
            seen.append(key)
            self._db.execute(
                f"INSERT INTO offers ({', '.join(COLUMNS)}) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) "
                "ON CONFLICT(id) DO UPDATE SET last_seen = excluded.last_seen, status = 'open', "
                "client = excluded.client, agency = excluded.agency",
                (key, store, day, kind, str(offer.get("client", ""))[:120], str(offer.get("agency", ""))[:60],
                 now, now, OPEN))
        marks = ",".join("?" * len(seen)) or "''"
        self._db.execute(f"UPDATE offers SET status = ? WHERE status = ? AND id NOT IN ({marks})", (GONE, OPEN, *seen))
        self._db.execute("DELETE FROM offers WHERE status = ? AND last_seen < ?", (GONE, now - KEEP_GONE))
        self._db.commit()
        return len(seen)

    def open(self, ignore: list[str] = ()) -> list[dict]:
        rows = self._db.execute(f"SELECT {', '.join(COLUMNS)} FROM offers WHERE status = ? ORDER BY day", (OPEN,))
        offers = [dict(zip(COLUMNS, row)) for row in rows]
        return [o for o in offers if not any(w in f"{o['store']} {o['kind']} {o['client']}".lower() for w in ignore)]

    def last_read(self) -> float | None:
        (last,) = self._db.execute("SELECT MAX(last_seen) FROM offers").fetchone()
        return last

    def context(self, offers: list[dict]) -> str:
        """The open offers with their conflicts, for the Recrutements assistant's note."""
        if not offers:
            return "Aucune offre de recrutement en attente de réponse."
        lines = ["Offres de recrutement RMA en attente de réponse (l'utilisateur accepte ou refuse lui-même dans "
                 "le portail ; tu ne peux que conseiller) :"]
        for o in offers:
            day = datetime.fromtimestamp(o["day"], self.tz)
            note = f" — ⚠️ {o['conflict']}" if o.get("conflict") else (" — passée" if o.get("past") else " — libre")
            lines.append(f"- {day:%d/%m/%Y} · {o['store']} · {o['kind']} · {o['client']}{note}")
        return "\n".join(lines)
