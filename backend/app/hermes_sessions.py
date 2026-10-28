"""Transport identities only: Hermes owns the conversation and its transcript.

Keep the session id returned by Chat Completions across Marcel restarts. The endpoint and bot
are part of the key so a fallback to the main profile never resumes a bot's own transcript.
"""

import asyncio
import hashlib
import json
import sqlite3
from contextlib import asynccontextmanager
from pathlib import Path
from weakref import WeakValueDictionary


class HermesSessions:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._db.execute("""CREATE TABLE IF NOT EXISTS hermes_sessions (
            endpoint TEXT NOT NULL, bot TEXT NOT NULL, conversation_id TEXT NOT NULL,
            session_id TEXT NOT NULL, input_count INTEGER NOT NULL, input_digest TEXT NOT NULL,
            PRIMARY KEY (endpoint, bot, conversation_id)
        )""")
        self._db.commit()
        self._locks = WeakValueDictionary()

    def get(self, endpoint: str, bot: str, conversation_id: str, messages: list[dict]) -> str | None:
        row = self._db.execute(
            "SELECT session_id, input_count, input_digest FROM hermes_sessions "
            "WHERE endpoint=? AND bot=? AND conversation_id=?",
            (endpoint, bot, conversation_id)).fetchone()
        if (row and len(messages) == row[1] + 2 and messages[-2]["role"] == "assistant"
                and messages[-1]["role"] == "user" and fingerprint(messages[:row[1]]) == row[2]):
            return row[0]
        # Editing, regenerating or trimming a chat starts a new transcript, never a continuation
        # of the hidden old branch. Store only a digest of the input, no duplicate transcript.
        return None

    def put(self, endpoint: str, bot: str, conversation_id: str, session_id: str, messages: list[dict]) -> None:
        with self._db:
            self._db.execute("INSERT OR REPLACE INTO hermes_sessions VALUES (?, ?, ?, ?, ?, ?)",
                             (endpoint, bot, conversation_id, session_id, len(messages), fingerprint(messages)))

    def clear(self) -> None:
        with self._db:
            self._db.execute("DELETE FROM hermes_sessions")

    @asynccontextmanager
    async def turn(self, endpoint: str, bot: str, conversation_id: str):
        """Serialize turns of one conversation, including two simultaneous first messages."""
        identity = (endpoint, bot, conversation_id)
        lock = self._locks.get(identity)
        if lock is None:
            lock = asyncio.Lock()
            self._locks[identity] = lock
        async with lock:
            yield


def fingerprint(messages: list[dict]) -> str:
    return hashlib.sha256(json.dumps(messages, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
