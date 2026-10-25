"""Search by meaning: "missions validées" finds "45 missions lues" though they share one word.

Each piece of data (a memory, a chunk of a past reply, a planning mission) gets an embedding (a
vector from an OpenAI-compatible `/v1/embeddings`, through the LLM guard on the VPS), stored in
SQLite next to the rest. A question is embedded too, and the closest vectors are the answer
(cosine similarity, computed in memory with numpy: Marcel's data stays in the thousands).

Without an embedding model (local tests, MARCEL_MOCK=1), a local stand-in hashes words and
pieces of words: it finds "validées" from "valider", not synonyms, but runs the whole pipeline.
"""

import hashlib
import json
import logging
import re
import sqlite3
import time
import unicodedata
from dataclasses import dataclass
from pathlib import Path

import httpx
import numpy as np

log = logging.getLogger("marcel.semantic")

LOCAL_MODEL = "local-hash"
LOCAL_DIM = 512
BATCH = 32


def digest(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def plain(text: str) -> str:
    return unicodedata.normalize("NFKD", text.lower()).encode("ascii", "ignore").decode()


class Embedder:
    """Turns texts into unit vectors, with the configured model or the local stand-in."""

    def __init__(self, url: str = "", key: str = "", model: str = "", min_score: float | None = None):
        self.local = not url or model == LOCAL_MODEL
        self.url, self.key = url.rstrip("/"), key
        self.model = LOCAL_MODEL if self.local else model
        # Cosine scores don't mean the same with every model: below this, a hit is noise.
        self.min_score = min_score if min_score is not None else (0.3 if self.local else 0.5)

    async def embed(self, texts: list[str]) -> np.ndarray:
        if not texts:
            return np.zeros((0, LOCAL_DIM), dtype=np.float32)
        if self.local:
            vectors = np.stack([self._hash(t) for t in texts])
        else:
            vectors = np.concatenate([await self._remote(texts[i:i + BATCH]) for i in range(0, len(texts), BATCH)])
        norms = np.linalg.norm(vectors, axis=1, keepdims=True)
        return (vectors / np.where(norms == 0, 1, norms)).astype(np.float32)

    async def _remote(self, texts: list[str]) -> np.ndarray:
        headers = {"Authorization": f"Bearer {self.key}"} if self.key else {}
        async with httpx.AsyncClient(timeout=httpx.Timeout(60, connect=10)) as client:
            resp = await client.post(f"{self.url}/v1/embeddings", headers=headers,
                                     json={"model": self.model, "input": texts})
            resp.raise_for_status()
            data = sorted(resp.json()["data"], key=lambda d: d["index"])
        return np.array([d["embedding"] for d in data], dtype=np.float32)

    @staticmethod
    def _hash(text: str) -> np.ndarray:
        """Words and their 4-letter pieces, hashed into a fixed-size vector."""
        vector = np.zeros(LOCAL_DIM, dtype=np.float32)
        for word in re.findall(r"[a-z0-9]+", plain(text)):
            features = [word] + [word[i:i + 4] for i in range(max(1, len(word) - 3))]
            for feature in features:
                h = int(hashlib.md5(feature.encode()).hexdigest()[:8], 16)
                vector[h % LOCAL_DIM] += 1.0 if feature == word else 0.5
        return vector


@dataclass
class Hit:
    kind: str
    ref: str
    score: float
    text: str
    meta: dict


class SemanticIndex:
    """Vectors by (kind, ref): "memoire" / fact id, "reponse" / mission id:chunk, "planning" / id."""

    def __init__(self, db_path: Path):
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        self._db.execute(
            """CREATE TABLE IF NOT EXISTS vectors (
                kind TEXT NOT NULL,
                ref TEXT NOT NULL,
                model TEXT NOT NULL,
                digest TEXT NOT NULL,
                text TEXT NOT NULL,
                meta TEXT NOT NULL DEFAULT '{}',
                vector BLOB NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (kind, ref)
            )"""
        )
        self._db.commit()
        # kind → (refs, matrix, texts, metas), rebuilt after a write.
        self._cache: dict[str, tuple[list[str], np.ndarray, list[str], list[dict]]] = {}

    def known(self, kind: str) -> dict[str, tuple[str, str]]:
        """ref → (digest of the text, model) for what is already indexed."""
        rows = self._db.execute("SELECT ref, digest, model FROM vectors WHERE kind = ?", (kind,))
        return {ref: (d, model) for ref, d, model in rows}

    def put(self, kind: str, model: str, items: list[tuple[str, str, dict]], vectors: np.ndarray) -> None:
        now = time.time()
        self._db.executemany(
            "INSERT OR REPLACE INTO vectors (kind, ref, model, digest, text, meta, vector, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [(kind, ref, model, digest(text), text, json.dumps(meta, ensure_ascii=False), vector.tobytes(), now)
             for (ref, text, meta), vector in zip(items, vectors)])
        self._db.commit()
        self._cache.pop(kind, None)

    def remove(self, kind: str, refs: list[str]) -> None:
        self._db.executemany("DELETE FROM vectors WHERE kind = ? AND ref = ?", [(kind, r) for r in refs])
        self._db.commit()
        self._cache.pop(kind, None)

    def count(self) -> dict[str, int]:
        return dict(self._db.execute("SELECT kind, COUNT(*) FROM vectors GROUP BY kind").fetchall())

    def search(self, query: np.ndarray, kind: str, model: str, limit: int = 8, min_score: float = 0.0) -> list[Hit]:
        """The closest items of a kind, best first, above `min_score`."""
        refs, matrix, texts, metas = self._load(kind, model)
        if not refs:
            return []
        scores = matrix @ query
        best = np.argsort(-scores)[:limit]
        return [Hit(kind, refs[i], float(scores[i]), texts[i], metas[i]) for i in best if scores[i] >= min_score]

    def _load(self, kind: str, model: str):
        if kind not in self._cache:
            rows = self._db.execute("SELECT ref, text, meta, vector FROM vectors WHERE kind = ? AND model = ?",
                                    (kind, model)).fetchall()
            refs = [r[0] for r in rows]
            matrix = (np.stack([np.frombuffer(r[3], dtype=np.float32) for r in rows])
                      if rows else np.zeros((0, 1), dtype=np.float32))
            self._cache[kind] = (refs, matrix, [r[1] for r in rows], [json.loads(r[2]) for r in rows])
        return self._cache[kind]
