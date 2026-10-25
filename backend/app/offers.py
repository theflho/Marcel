"""Recruitment offers from the RMA portal ("Recrutements › Attente de réponse"), read by the rma
robot, and the user's answers to them.

An answer is given in the portal by the robot only after the user's "Oui" in the app, one offer
at a time; the portal's own rules stay in force (no answer while it reports a conflict).
"""

from __future__ import annotations

import hashlib
import sqlite3
import time
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

COLUMNS = ("id", "store", "day", "kind", "client", "agency", "first_seen", "last_seen", "status",
           "date_text", "start_at", "end_at", "portal_conflict", "can_answer", "link",
           "answer", "answer_status", "answer_message", "answered_at")
# Added after the first version.
NEW_COLUMNS = {"date_text": "TEXT NOT NULL DEFAULT ''", "start_at": "REAL", "end_at": "REAL",
               "portal_conflict": "TEXT NOT NULL DEFAULT ''", "can_answer": "INTEGER NOT NULL DEFAULT 0",
               "link": "TEXT NOT NULL DEFAULT ''", "answer": "TEXT NOT NULL DEFAULT ''",
               "answer_status": "TEXT NOT NULL DEFAULT ''", "answer_message": "TEXT NOT NULL DEFAULT ''",
               "answered_at": "REAL"}
OPEN, GONE = "open", "gone"
PENDING, DONE, FAILED = "pending", "done", "failed"
# Offers no longer shown (answered, withdrawn) are kept a while, then forgotten.
KEEP_GONE = 30 * 86_400
# An answer stays visible on its card this long.
SHOW_ANSWERED = 7 * 86_400
MONTHS = {"janv": 1, "févr": 2, "fevr": 2, "mars": 3, "avr": 4, "mai": 5, "juin": 6, "juil": 7, "août": 8,
          "aout": 8, "sept": 9, "oct": 10, "nov": 11, "déc": 12, "dec": 12}


def parse_day(text: str, tz: ZoneInfo | None) -> datetime | None:
    """ "19 oct. 2026" → midnight of that day, or None."""
    parts = text.replace(".", "").split()
    if len(parts) != 3:
        return None
    day, month, year = parts
    number = MONTHS.get(month.lower()[:5]) or MONTHS.get(month.lower()[:4])
    try:
        return datetime(int(year), number, int(day), tzinfo=tz) if number else None
    except ValueError:
        return None


def at(day: datetime, clock: str) -> float | None:
    try:
        hour, minute = (int(part) for part in clock.split(":"))
        return day.replace(hour=hour, minute=minute).timestamp()
    except (ValueError, AttributeError):
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
        existing = {row[1] for row in self._db.execute("PRAGMA table_info(offers)")}
        for name, kind in NEW_COLUMNS.items():
            if name not in existing:
                self._db.execute(f"ALTER TABLE offers ADD COLUMN {name} {kind}")
        self._db.commit()

    def replace(self, offers: list[dict]) -> int:
        """What the robot sees now; open offers it no longer sees were answered or withdrawn."""
        now = time.time()
        seen = []
        for offer in offers:
            date_text = " ".join(str(offer.get("date", "")).split())[:40]
            day = parse_day(date_text, self.tz)
            store = " ".join(str(offer.get("store", "")).split())[:120]
            if day is None or not store:
                continue
            kind = " ".join(str(offer.get("kind", "")).split())[:120]
            key = hashlib.sha256(f"{day.timestamp()}|{store}|{kind}".encode()).hexdigest()[:16]
            seen.append(key)
            start = at(day, offer.get("start") or "")
            end = at(day, offer.get("end") or "")
            if start is not None and end is not None and end <= start:
                end = at(day + timedelta(days=1), offer["end"])
            self._db.execute(
                f"INSERT INTO offers ({', '.join(COLUMNS[:15])}) VALUES ({', '.join('?' * 15)}) "
                "ON CONFLICT(id) DO UPDATE SET last_seen = excluded.last_seen, status = 'open', "
                "client = excluded.client, agency = excluded.agency, date_text = excluded.date_text, "
                "start_at = COALESCE(excluded.start_at, start_at), end_at = COALESCE(excluded.end_at, end_at), "
                "portal_conflict = excluded.portal_conflict, can_answer = excluded.can_answer, "
                "link = CASE WHEN excluded.link != '' THEN excluded.link ELSE link END",
                (key, store, day.timestamp(), kind, str(offer.get("client", ""))[:120],
                 str(offer.get("agency", ""))[:60], now, now, OPEN, date_text, start, end,
                 str(offer.get("portal_conflict", ""))[:400], int(bool(offer.get("can_answer"))),
                 str(offer.get("link", ""))[:300]))
        marks = ",".join("?" * len(seen)) or "''"
        self._db.execute(f"UPDATE offers SET status = ? WHERE status = ? AND id NOT IN ({marks})", (GONE, OPEN, *seen))
        self._db.execute("DELETE FROM offers WHERE status = ? AND last_seen < ?", (GONE, now - KEEP_GONE))
        self._db.commit()
        return len(seen)

    def _rows(self, where: str, args: tuple) -> list[dict]:
        rows = self._db.execute(f"SELECT {', '.join(COLUMNS)} FROM offers WHERE {where} ORDER BY day", args)
        offers = [dict(zip(COLUMNS, row)) for row in rows]
        for offer in offers:
            offer["can_answer"] = bool(offer["can_answer"])
        return offers

    def visible(self, ignore: list[str] = ()) -> list[dict]:
        """Offers waiting for an answer, and those answered lately (to show how it went)."""
        offers = self._rows("status = ? OR (answer_status != '' AND answered_at > ?)",
                            (OPEN, time.time() - SHOW_ANSWERED))
        return [o for o in offers if not any(w in f"{o['store']} {o['kind']} {o['client']}".lower() for w in ignore)]

    def answered(self, since: float) -> list[dict]:
        """Offers the user answered (through the robot) since then, accepted or refused."""
        return self._rows("answer != '' AND answered_at > ?", (since,))

    def all(self) -> list[dict]:
        """Every offer kept: waiting, answered, or gone from the portal (30 days)."""
        return self._rows("1 = 1", ())

    def get(self, offer_id: str) -> dict | None:
        found = self._rows("id = ?", (offer_id,))
        return found[0] if found else None

    def ask(self, offer_id: str, answer: str) -> None:
        """The user said "Oui": the robot gives this answer on its next round (within 10 minutes)."""
        self._db.execute("UPDATE offers SET answer = ?, answer_status = ?, answer_message = '', answered_at = ? "
                         "WHERE id = ?", (answer, PENDING, time.time(), offer_id))
        self._db.commit()

    def cancel(self, offer_id: str) -> None:
        self._db.execute("UPDATE offers SET answer = '', answer_status = '', answer_message = '', answered_at = NULL "
                         "WHERE id = ? AND answer_status = ?", (offer_id, PENDING))
        self._db.commit()

    def pending(self) -> list[dict]:
        return self._rows("answer_status = ? AND status = ?", (PENDING, OPEN))

    def settle(self, offer_id: str, ok: bool, message: str) -> None:
        self._db.execute("UPDATE offers SET answer_status = ?, answer_message = ?, answered_at = ? WHERE id = ?",
                         (DONE if ok else FAILED, message[:300], time.time(), offer_id))
        self._db.commit()

    def last_read(self) -> float | None:
        (last,) = self._db.execute("SELECT MAX(last_seen) FROM offers").fetchone()
        return last

    def context(self, offers: list[dict]) -> str:
        """The offers with their conflicts, for the Offres RMA bot's note."""
        waiting = [o for o in offers if o["status"] == OPEN]
        if not waiting:
            return "Aucune offre de recrutement en attente de réponse."
        lines = ["Offres de recrutement RMA en attente de réponse (l'utilisateur répond avec les boutons de l'app, "
                 "le robot n'agit qu'après son « Oui » ; toi, tu conseilles seulement) :"]
        for o in waiting:
            day = datetime.fromtimestamp(o["day"], self.tz)
            hours = ""
            if o["start_at"] and o["end_at"]:
                hours = (f" {datetime.fromtimestamp(o['start_at'], self.tz):%H:%M}-"
                         f"{datetime.fromtimestamp(o['end_at'], self.tz):%H:%M}")
            notes = [n for n in (o.get("day_note"), o.get("portal_conflict"), o.get("conflict")) if n]
            if o.get("past"):
                notes.append("date passée")
            if o["answer_status"] == PENDING:
                notes.append("réponse en cours d'envoi")
            lines.append(f"- {day:%d/%m/%Y}{hours} · {o['store']} · {o['kind']} · {o['client']} — "
                         + ("; ".join(notes) if notes else "libre"))
        return "\n".join(lines)
