"""LLM guard: the only way to the model provider, with a daily token budget.

Hermes (app and Telegram), hermes-checks and Marcel's memory call this proxy instead of
Scaleway. It forwards OpenAI-compatible requests, adds up the tokens the provider reports,
and refuses new requests (429) once the day's budget is spent, until midnight (server time).
Automatic checks stop earlier, so a share of the budget stays for the user's own messages.

Each caller has its own key, so usage is counted per caller and the provider key stays here.

    uvicorn app.llm_guard:app --port 4000
"""

import json
import logging
import os
import secrets
import sqlite3
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse

UPSTREAM_URL = os.environ.get("GUARD_UPSTREAM_URL", "https://api.scaleway.ai/v1").rstrip("/")
UPSTREAM_KEY = os.environ.get("GUARD_UPSTREAM_KEY", "")
DAILY_TOKENS = int(os.environ.get("GUARD_DAILY_TOKENS") or 2_000_000)
# Automatic checks stop once this share of the day's budget is spent.
CHECKS_SHARE = float(os.environ.get("GUARD_CHECKS_SHARE") or 0.6)
CHECKS_CLIENT = "checks"
DATA_DIR = Path(os.environ.get("GUARD_DATA_DIR", "/data"))
# Headers that must not be copied from one connection to the other.
HOP_HEADERS = {"host", "content-length", "connection", "transfer-encoding", "authorization",
               "accept-encoding", "content-encoding", "keep-alive"}

log = logging.getLogger("marcel.guard")


def parse_keys(raw: str) -> dict[str, str]:
    """GUARD_KEYS="hermes=<key>,checks=<key>,marcel=<key>" → {key: caller}."""
    keys = {}
    for item in filter(None, (part.strip() for part in raw.split(","))):
        name, _, key = item.partition("=")
        if name.strip() and key.strip():
            keys[key.strip()] = name.strip()
    return keys


KEYS = parse_keys(os.environ.get("GUARD_KEYS", ""))


class Usage:
    def __init__(self, db_path: Path):
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        self._db.execute(
            """CREATE TABLE IF NOT EXISTS usage (
                day TEXT NOT NULL,
                client TEXT NOT NULL,
                prompt_tokens INTEGER NOT NULL DEFAULT 0,
                completion_tokens INTEGER NOT NULL DEFAULT 0,
                requests INTEGER NOT NULL DEFAULT 0,
                refused INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (day, client)
            )"""
        )
        self._db.commit()

    @staticmethod
    def today() -> str:
        return time.strftime("%Y-%m-%d", time.localtime())

    def add(self, client: str, prompt: int = 0, completion: int = 0, requests: int = 0, refused: int = 0) -> None:
        self._db.execute(
            """INSERT INTO usage (day, client, prompt_tokens, completion_tokens, requests, refused)
               VALUES (?, ?, ?, ?, ?, ?)
               ON CONFLICT (day, client) DO UPDATE SET
                   prompt_tokens = prompt_tokens + excluded.prompt_tokens,
                   completion_tokens = completion_tokens + excluded.completion_tokens,
                   requests = requests + excluded.requests, refused = refused + excluded.refused""",
            (self.today(), client, prompt, completion, requests, refused))
        self._db.commit()

    def spent(self) -> int:
        row = self._db.execute("SELECT COALESCE(SUM(prompt_tokens + completion_tokens), 0) FROM usage WHERE day = ?",
                               (self.today(),)).fetchone()
        return row[0]

    def report(self) -> dict:
        rows = self._db.execute("SELECT client, prompt_tokens, completion_tokens, requests, refused FROM usage "
                                "WHERE day = ?", (self.today(),))
        clients = {client: {"prompt_tokens": p, "completion_tokens": c, "requests": r, "refused": f}
                   for client, p, c, r, f in rows}
        return {"day": self.today(), "tokens": self.spent(), "budget": DAILY_TOKENS,
                "checks_budget": int(DAILY_TOKENS * CHECKS_SHARE), "clients": clients}


usage = Usage(DATA_DIR / "guard.db")
# One client for every request: keep-alive connections to the provider save a TLS handshake
# (about 100 ms) on each of the many calls an agent makes for a single answer.
upstream = httpx.AsyncClient(timeout=httpx.Timeout(connect=10, read=600, write=60, pool=30),
                             limits=httpx.Limits(max_connections=50, max_keepalive_connections=20))


@asynccontextmanager
async def lifespan(_: FastAPI):
    yield
    await upstream.aclose()


app = FastAPI(title="Marcel LLM guard", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)


def caller(authorization: str) -> str:
    scheme, _, key = authorization.partition(" ")
    if scheme.lower() == "bearer":
        for known, name in KEYS.items():
            if secrets.compare_digest(key, known):
                return name
    raise HTTPException(401, "Invalid key")


def refusal(client: str) -> str | None:
    """Why this caller can't spend more today, or None."""
    spent = usage.spent()
    if spent >= DAILY_TOKENS:
        return f"Budget du jour atteint ({spent} tokens sur {DAILY_TOKENS}). Reprise à minuit."
    if client == CHECKS_CLIENT and spent >= DAILY_TOKENS * CHECKS_SHARE:
        return "Budget du jour réservé aux messages de l'utilisateur : vérifications automatiques en pause."
    return None


def count(client: str, data: dict) -> None:
    """Adds the usage block of a provider response (or stream chunk), if any."""
    if isinstance(data, dict) and isinstance(data.get("usage"), dict):
        u = data["usage"]
        usage.add(client, prompt=int(u.get("prompt_tokens") or u.get("input_tokens") or 0),
                  completion=int(u.get("completion_tokens") or u.get("output_tokens") or 0))


@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "upstream": UPSTREAM_URL, "keys": sorted(set(KEYS.values()))}


@app.get("/usage")
async def get_usage(authorization: str = Header(default="")) -> dict:
    caller(authorization)
    return usage.report()


@app.api_route("/v1/{path:path}", methods=["GET", "POST"])
async def proxy(path: str, request: Request, authorization: str = Header(default="")) -> Response:
    client = caller(authorization)
    body = await request.body()
    if request.method == "POST" and (reason := refusal(client)):
        usage.add(client, refused=1)
        log.warning("refused %s: %s", client, reason)
        return JSONResponse({"error": {"message": reason, "type": "insufficient_quota", "code": "daily_budget"}},
                            status_code=429)
    payload = None
    if body and request.headers.get("content-type", "").startswith("application/json"):
        try:
            payload = json.loads(body)
        except ValueError:
            payload = None
    if isinstance(payload, dict) and payload.get("stream"):
        # Without this, providers don't report usage at the end of a stream.
        payload["stream_options"] = {**(payload.get("stream_options") or {}), "include_usage": True}
        body = json.dumps(payload).encode()
    headers = {k: v for k, v in request.headers.items() if k.lower() not in HOP_HEADERS}
    headers["Authorization"] = f"Bearer {UPSTREAM_KEY}"
    if request.method == "POST":
        usage.add(client, requests=1)

    upstream_request = upstream.build_request(request.method, f"{UPSTREAM_URL}/{path}", content=body or None,
                                              headers=headers, params=request.query_params)
    try:
        resp = await upstream.send(upstream_request, stream=True)
    except httpx.HTTPError:
        log.exception("upstream unreachable")
        return JSONResponse({"error": {"message": "Fournisseur du modèle injoignable."}}, status_code=502)
    out_headers = {k: v for k, v in resp.headers.items() if k.lower() not in HOP_HEADERS}

    if resp.headers.get("content-type", "").startswith("text/event-stream"):
        async def relay() -> AsyncIterator[bytes]:
            try:
                async for line in resp.aiter_lines():
                    if line.startswith("data:") and '"usage"' in line:
                        try:
                            count(client, json.loads(line[5:].strip()))
                        except ValueError:
                            pass
                    yield (line + "\n").encode()
            finally:
                await resp.aclose()

        return StreamingResponse(relay(), status_code=resp.status_code, headers=out_headers,
                                 media_type="text/event-stream")

    try:
        content = await resp.aread()
    finally:
        await resp.aclose()
    if resp.headers.get("content-type", "").startswith("application/json"):
        try:
            count(client, json.loads(content))
        except ValueError:
            pass
    return Response(content, status_code=resp.status_code, headers=out_headers)
