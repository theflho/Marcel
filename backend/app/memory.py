"""Marcel's memory, in three tiers, so it never fills up.

- Core: a few stable facts, sent with every mission. Kept under a character budget.
- Archive: everything else, unlimited. Only the facts related to the question are sent.
- Tidying (nightly, or on demand): expires old facts, merges duplicates, promotes facts that
  are used often to the core and demotes the ones that aren't.

Every change is written to a log with the fact before and after, so any of them can be undone.
"""

import json
import re
import secrets
import sqlite3
import time
import unicodedata
from dataclasses import dataclass
from pathlib import Path

CORE, ARCHIVE = "core", "archive"
ACTIVE, EXPIRED, DELETED, MERGED = "active", "expired", "deleted", "merged"
DAY = 86400
# A core fact nobody needed for this long goes back to the archive.
DEMOTE_AFTER = 60 * DAY
# An archived fact used this often recently is promoted to the core.
PROMOTE_USES, PROMOTE_WINDOW = 3, 30 * DAY
# Promotion stops when the core reaches this share of its budget, to leave room.
PROMOTE_CEILING = 0.8
# Two facts sharing this share of their words are duplicates.
DUPLICATE_SIMILARITY = 0.75
MAX_FACT_CHARS = 300

COLUMNS = ("id", "text", "tier", "importance", "pinned", "source", "created_at", "updated_at",
           "last_used_at", "uses", "expires_at", "status", "owner")
STOPWORDS = set("""le la les un une des de du d l et ou a à au aux en dans sur pour par avec sans ce cet cette
ces que qui quoi est sont été être avoir ai as il elle ils elles on je j tu nous vous me m te t se s
mon ma mes ton ta tes son sa ses leur leurs ne pas plus très bien aussi mais donc car comme si y
utilisateur""".split())


@dataclass
class Fact:
    id: str
    text: str
    tier: str = ARCHIVE
    importance: int = 3
    pinned: bool = False
    source: str = ""
    created_at: float = 0.0
    updated_at: float = 0.0
    last_used_at: float | None = None
    uses: int = 0
    expires_at: float | None = None
    status: str = ACTIVE
    # The bot that learnt it ("" = Marcel's, shared by all): only that bot and Marcel's list see it.
    owner: str = ""

    def public(self) -> dict:
        return {c: getattr(self, c) for c in COLUMNS}

    @property
    def score(self) -> float:
        """How much a fact deserves a place in the core."""
        recent = 1.0 if self.last_used_at and time.time() - self.last_used_at < PROMOTE_WINDOW else 0.0
        return self.importance * 2 + min(self.uses, 10) + recent * 3


def words(text: str) -> set[str]:
    plain = unicodedata.normalize("NFKD", text.lower()).encode("ascii", "ignore").decode()
    return {w for w in re.findall(r"[a-z0-9]+", plain) if len(w) > 2 and w not in STOPWORDS}


def similarity(a: str, b: str) -> float:
    wa, wb = words(a), words(b)
    if not wa or not wb:
        return 0.0
    return len(wa & wb) / len(wa | wb)


class MemoryStore:
    def __init__(self, db_path: Path, core_budget: int = 1500):
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self.core_budget = core_budget
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        self._db.executescript(
            """CREATE TABLE IF NOT EXISTS memories (
                id TEXT PRIMARY KEY,
                text TEXT NOT NULL,
                tier TEXT NOT NULL DEFAULT 'archive',
                importance INTEGER NOT NULL DEFAULT 3,
                pinned INTEGER NOT NULL DEFAULT 0,
                source TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                last_used_at REAL,
                uses INTEGER NOT NULL DEFAULT 0,
                expires_at REAL,
                status TEXT NOT NULL DEFAULT 'active'
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(id UNINDEXED, text);
            CREATE TABLE IF NOT EXISTS memory_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                at REAL NOT NULL,
                action TEXT NOT NULL,
                memory_id TEXT NOT NULL,
                before TEXT,
                after TEXT,
                reason TEXT NOT NULL DEFAULT '',
                batch TEXT,
                undone INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS memory_meta (name TEXT PRIMARY KEY, value TEXT NOT NULL);"""
        )
        if "owner" not in {row[1] for row in self._db.execute("PRAGMA table_info(memories)")}:
            self._db.execute("ALTER TABLE memories ADD COLUMN owner TEXT NOT NULL DEFAULT ''")
        self._db.commit()

    # MARK: Reading

    def get(self, fact_id: str) -> Fact | None:
        row = self._db.execute(f"SELECT {', '.join(COLUMNS)} FROM memories WHERE id = ?", (fact_id,)).fetchone()
        return self._fact(row) if row else None

    def active(self, tier: str | None = None, owner: str | None = None) -> list[Fact]:
        """Active facts; with `owner`, only those that one sees: the shared ones and its own."""
        query = f"SELECT {', '.join(COLUMNS)} FROM memories WHERE status = ?"
        params: list = [ACTIVE]
        if tier:
            query += " AND tier = ?"
            params.append(tier)
        if owner is not None:
            query += " AND owner IN ('', ?)"
            params.append(owner)
        rows = self._db.execute(query + " ORDER BY importance DESC, updated_at DESC", params)
        return [self._fact(row) for row in rows]

    def search(self, text: str, limit: int = 10, tier: str | None = None, owner: str | None = None) -> list[Fact]:
        """Active facts sharing words with `text`, best matches first."""
        terms = words(text)
        if not terms:
            return []
        match = " OR ".join(f'"{t}"*' for t in terms)
        rows = self._db.execute(
            "SELECT id FROM memories_fts WHERE memories_fts MATCH ? ORDER BY bm25(memories_fts) LIMIT ?",
            (match, limit * 3),
        ).fetchall()
        facts = [f for (fact_id,) in rows if (f := self.get(fact_id)) and f.status == ACTIVE
                 and (tier is None or f.tier == tier) and (owner is None or f.owner in ("", owner))]
        return facts[:limit]

    def core_chars(self) -> int:
        return sum(len(f.text) for f in self.active(CORE))

    def stats(self) -> dict:
        core = self.active(CORE)
        used = sum(len(f.text) for f in core)
        return {
            "core_chars": used,
            "core_budget": self.core_budget,
            "core_count": len(core),
            "archive_count": len(self.active(ARCHIVE)),
            "last_tidy": float(v) if (v := self._meta("last_tidy")) else None,
        }

    def log(self, limit: int = 100) -> list[dict]:
        rows = self._db.execute(
            "SELECT id, at, action, memory_id, before, after, reason, batch, undone FROM memory_log "
            "ORDER BY id DESC LIMIT ?", (limit,))
        entries = []
        for entry_id, at, action, memory_id, before, after, reason, batch, undone in rows:
            before, after = json.loads(before) if before else None, json.loads(after) if after else None
            entries.append({
                "id": entry_id, "at": at, "action": action, "memory_id": memory_id,
                "before": before and before["text"], "after": after and after["text"],
                "tier": (after or before or {}).get("tier"), "reason": reason, "batch": batch,
                "undone": bool(undone),
            })
        return entries

    # MARK: Context for a mission

    def context(self, question: str, archive_limit: int = 8, close: list[str] = (),
                owner: str = "") -> tuple[str, list[Fact]]:
        """The system note sent with a mission: the whole core, plus archived facts related
        to the question: `close` (ids found by meaning, best first), then facts sharing words.
        Only what `owner` sees (Marcel: the shared facts; a bot: those and its own).
        Facts sent are counted as used."""
        core = self.active(CORE, owner)
        by_meaning = [f for i in close if (f := self.get(i)) and f.status == ACTIVE and f.owner in ("", owner)]
        seen = {f.id for f in by_meaning}
        related = by_meaning + [f for f in self.search(question, limit=archive_limit + len(core), owner=owner)
                                if f.id not in seen]
        now = time.time()
        for fact in related:
            self._db.execute("UPDATE memories SET uses = uses + 1, last_used_at = ? WHERE id = ?", (now, fact.id))
        self._db.commit()
        archived = [f for f in related if f.tier == ARCHIVE][:archive_limit]
        if not core and not archived:
            return "", []
        lines = ["Ce que Marcel sait de l'utilisateur (à utiliser seulement si c'est utile, sans le réciter) :"]
        lines += [f"- {f.text}" for f in core if not f.owner]
        if own := [f for f in core + archived if f.owner]:
            lines.append("Ce que tu as appris toi-même, dans tes conversations :")
            lines += [f"- {f.text}" for f in own]
        if shared := [f for f in archived if not f.owner]:
            lines.append("Souvenirs liés à cette demande :")
            lines += [f"- {f.text}" for f in shared]
        return "\n".join(lines), core + archived

    # MARK: Writing

    def add(self, text: str, *, tier: str = ARCHIVE, importance: int = 3, pinned: bool = False,
            source: str = "", expires_at: float | None = None, reason: str = "", batch: str | None = None,
            owner: str = "") -> Fact:
        """Adds a fact (a bot's own when `owner` is set), or refreshes the existing one when it's a duplicate."""
        text = " ".join(text.split())[:MAX_FACT_CHARS]
        if duplicate := self.find_duplicate(text, owner):
            changes = {"text": text if len(text) >= len(duplicate.text) else duplicate.text,
                       "importance": max(duplicate.importance, importance)}
            if expires_at and (duplicate.expires_at or 0) < expires_at:
                changes["expires_at"] = expires_at
            return self.update(duplicate.id, reason=reason or "doublon rafraîchi", batch=batch, **changes)
        now = time.time()
        fact = Fact(id=secrets.token_hex(6), text=text, tier=tier, importance=max(1, min(5, importance)),
                    pinned=pinned, source=source, created_at=now, updated_at=now, expires_at=expires_at,
                    owner=owner)
        self._write(None, fact, "add", reason, batch)
        return fact

    def update(self, fact_id: str, *, reason: str = "", batch: str | None = None, **changes) -> Fact:
        before = self.get(fact_id)
        if not before:
            raise KeyError(fact_id)
        after = Fact(**before.public())
        for key, value in changes.items():
            setattr(after, key, value)
        after.text = " ".join(after.text.split())[:MAX_FACT_CHARS]
        after.importance = max(1, min(5, after.importance))
        if after.public() == before.public():
            return before
        after.updated_at = time.time()
        action = ("delete" if after.status == DELETED else "expire" if after.status == EXPIRED
                  else "merge" if after.status == MERGED
                  else "promote" if (before.tier, after.tier) == (ARCHIVE, CORE)
                  else "demote" if (before.tier, after.tier) == (CORE, ARCHIVE) else "edit")
        self._write(before, after, action, reason, batch)
        return after

    def delete(self, fact_id: str, reason: str = "supprimé à la main") -> Fact:
        return self.update(fact_id, status=DELETED, reason=reason)

    def find_duplicate(self, text: str, owner: str = "") -> Fact | None:
        for candidate in self.search(text, limit=5, owner=owner):
            if similarity(candidate.text, text) >= DUPLICATE_SIMILARITY:
                return candidate
        return None

    def undo(self, entry_id: int) -> int:
        """Undoes a log entry, or its whole batch (a tidying run). Returns how many changes were undone."""
        row = self._db.execute("SELECT batch FROM memory_log WHERE id = ?", (entry_id,)).fetchone()
        if not row:
            raise KeyError(entry_id)
        (batch,) = row
        if batch:
            rows = self._db.execute(
                "SELECT id, memory_id, before FROM memory_log WHERE batch = ? AND undone = 0 ORDER BY id DESC",
                (batch,)).fetchall()
        else:
            rows = self._db.execute(
                "SELECT id, memory_id, before FROM memory_log WHERE id = ? AND undone = 0", (entry_id,)).fetchall()
        for log_id, memory_id, before in rows:
            if before:
                self._store(Fact(**json.loads(before)))
            else:
                self._db.execute("DELETE FROM memories WHERE id = ?", (memory_id,))
                self._db.execute("DELETE FROM memories_fts WHERE id = ?", (memory_id,))
            self._db.execute("UPDATE memory_log SET undone = 1 WHERE id = ?", (log_id,))
        self._db.commit()
        return len(rows)

    # MARK: Tidying

    def tidy(self, merges: list[dict] | None = None, expire_ids: list[str] | None = None) -> dict:
        """Runs one tidying pass and returns what changed.

        `merges` ([{"ids": [...], "text": "..."}]) and `expire_ids` come from the model when it
        is available; the rules below run either way.
        """
        batch = f"rangement-{int(time.time())}"
        summary = {"batch": batch, "expired": 0, "merged": 0, "promoted": 0, "demoted": 0}
        now = time.time()

        for fact in self.active():
            if fact.expires_at and fact.expires_at < now and not fact.pinned:
                self.update(fact.id, status=EXPIRED, reason="date d'expiration passée", batch=batch)
                summary["expired"] += 1
        for fact_id in expire_ids or []:
            if (fact := self.get(fact_id)) and fact.status == ACTIVE and not fact.pinned:
                self.update(fact_id, status=EXPIRED, reason="périmé ou contredit (modèle)", batch=batch)
                summary["expired"] += 1

        for group in merges or []:
            facts = [f for i in group.get("ids", []) if (f := self.get(i)) and f.status == ACTIVE]
            if len(facts) >= 2 and group.get("text"):
                summary["merged"] += self._merge(facts, group["text"], batch, "fusionnés par le modèle")
        # Near-identical facts, merged even without the model.
        for fact in self.active():
            if (current := self.get(fact.id)) is None or current.status != ACTIVE:
                continue
            twins = [f for f in self.search(current.text, limit=6)
                     if f.id != current.id and similarity(f.text, current.text) >= DUPLICATE_SIMILARITY]
            if twins:
                keep = max([current, *twins], key=lambda f: f.updated_at)
                summary["merged"] += self._merge([current, *twins], keep.text, batch, "doublons")

        for fact in self.active(CORE):
            last = fact.last_used_at or fact.created_at
            if not fact.pinned and now - last > DEMOTE_AFTER:
                self.update(fact.id, tier=ARCHIVE, reason="pas utilisé depuis 60 jours", batch=batch)
                summary["demoted"] += 1

        used = self.core_chars()
        candidates = sorted(
            (f for f in self.active(ARCHIVE) if f.uses >= PROMOTE_USES and f.importance >= 3
             and f.last_used_at and now - f.last_used_at < PROMOTE_WINDOW),
            key=lambda f: f.score, reverse=True)
        for fact in candidates:
            if used + len(fact.text) > self.core_budget * PROMOTE_CEILING:
                continue
            self.update(fact.id, tier=CORE, reason=f"utilisé {fact.uses} fois récemment", batch=batch)
            used += len(fact.text)
            summary["promoted"] += 1

        # Over budget: the least useful core facts go back to the archive (pinned ones stay).
        for fact in sorted(self.active(CORE), key=lambda f: f.score):
            if self.core_chars() <= self.core_budget:
                break
            if not fact.pinned:
                self.update(fact.id, tier=ARCHIVE, reason="noyau plein", batch=batch)
                summary["demoted"] += 1

        self._set_meta("last_tidy", str(now))
        return summary | {"stats": self.stats()}

    def _merge(self, facts: list[Fact], text: str, batch: str, reason: str) -> int:
        """Keeps the first fact with the merged text and marks the others merged."""
        if len({f.owner for f in facts}) > 1:
            return 0  # a bot's own facts are never merged into another's
        keep, *others = sorted(facts, key=lambda f: (f.tier != CORE, -f.score))
        self.update(keep.id, text=text, importance=max(f.importance for f in facts),
                    uses=sum(f.uses for f in facts), pinned=any(f.pinned for f in facts),
                    last_used_at=max((f.last_used_at or 0) for f in facts) or None,
                    expires_at=None if any(f.expires_at is None for f in facts) else max(f.expires_at for f in facts),
                    reason=reason, batch=batch)
        for other in others:
            self.update(other.id, status=MERGED, reason=f"fusionné dans {keep.id}", batch=batch)
        return len(others)

    # MARK: Storage

    def _fact(self, row) -> Fact:
        fact = Fact(*row)
        fact.pinned = bool(fact.pinned)
        return fact

    def _store(self, fact: Fact) -> None:
        values = fact.public()
        values["pinned"] = int(fact.pinned)
        self._db.execute(
            f"INSERT OR REPLACE INTO memories ({', '.join(COLUMNS)}) VALUES ({', '.join('?' * len(COLUMNS))})",
            [values[c] for c in COLUMNS])
        self._db.execute("DELETE FROM memories_fts WHERE id = ?", (fact.id,))
        if fact.status == ACTIVE:
            self._db.execute("INSERT INTO memories_fts (id, text) VALUES (?, ?)", (fact.id, fact.text))

    def _write(self, before: Fact | None, after: Fact, action: str, reason: str, batch: str | None) -> None:
        self._store(after)
        self._db.execute(
            "INSERT INTO memory_log (at, action, memory_id, before, after, reason, batch) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (time.time(), action, after.id, before and json.dumps(before.public(), ensure_ascii=False),
             json.dumps(after.public(), ensure_ascii=False), reason, batch))
        self._db.commit()

    def _meta(self, name: str) -> str | None:
        row = self._db.execute("SELECT value FROM memory_meta WHERE name = ?", (name,)).fetchone()
        return row[0] if row else None

    def _set_meta(self, name: str, value: str) -> None:
        self._db.execute("INSERT OR REPLACE INTO memory_meta (name, value) VALUES (?, ?)", (name, value))
        self._db.commit()


def split_entries(text: str) -> list[str]:
    """Entries of a memory file to import: Hermes separates them with '§', otherwise one per line."""
    parts = text.split("§") if "§" in text else text.splitlines()
    entries = []
    for part in parts:
        part = re.sub(r"^\s*(?:[-*•]|\d+[.)])\s*", "", part.strip())
        if len(part) >= 3 and not part.startswith("#"):
            entries.append(part)
    return entries
