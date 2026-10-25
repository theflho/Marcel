"""LLM guard: the only way to the model provider, with a daily token budget.

Hermes (app and Telegram), hermes-checks and Marcel's memory call this proxy instead of
Scaleway. It forwards OpenAI-compatible requests, adds up the tokens the provider reports,
and refuses new requests (429) once the day's budget is spent, until midnight (server time).
Automatic checks stop earlier, so a share of the budget stays for the user's own messages.

Each caller has its own key, so usage is counted per caller and the provider key stays here.

A stronger model at another provider (the "renfort", e.g. Claude) can be routed by its model name
(GUARD_ROUTES), with its own key and its own daily budget, counted apart from the main one.

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


def parse_routes(raw: str) -> list[dict]:
    """GUARD_ROUTES="claude-|https://api.anthropic.com/v1|<key>|300000;…" → models whose name starts
    with the prefix go to that provider, with that key, up to that many tokens a day."""
    routes = []
    for item in filter(None, (part.strip() for part in raw.split(";"))):
        fields = [f.strip() for f in item.split("|")]
        if len(fields) < 3 or not fields[0] or not fields[1]:
            continue
        budget = int(fields[3]) if len(fields) > 3 and fields[3].isdigit() else 200_000
        routes.append({"prefix": fields[0], "url": fields[1].rstrip("/"), "key": fields[2], "budget": budget})
    return routes


ROUTES = parse_routes(os.environ.get("GUARD_ROUTES", ""))


def route_for(model: object) -> dict | None:
    return next((r for r in ROUTES if isinstance(model, str) and model.startswith(r["prefix"])), None)


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
        # Tokens spent on a routed provider: their own budget, apart from the main one.
        self._db.execute(
            """CREATE TABLE IF NOT EXISTS route_usage (
                day TEXT NOT NULL,
                route TEXT NOT NULL,
                client TEXT NOT NULL,
                tokens INTEGER NOT NULL DEFAULT 0,
                requests INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (day, route, client)
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

    def add_routed(self, route: str, client: str, tokens: int = 0, requests: int = 0) -> None:
        self._db.execute(
            """INSERT INTO route_usage (day, route, client, tokens, requests) VALUES (?, ?, ?, ?, ?)
               ON CONFLICT (day, route, client) DO UPDATE SET tokens = tokens + excluded.tokens,
                   requests = requests + excluded.requests""",
            (self.today(), route, client, tokens, requests))
        self._db.commit()

    def spent_routed(self, route: str) -> int:
        row = self._db.execute("SELECT COALESCE(SUM(tokens), 0) FROM route_usage WHERE day = ? AND route = ?",
                               (self.today(), route)).fetchone()
        return row[0]

    def spent(self) -> int:
        row = self._db.execute("SELECT COALESCE(SUM(prompt_tokens + completion_tokens), 0) FROM usage WHERE day = ?",
                               (self.today(),)).fetchone()
        return row[0]

    def report(self) -> dict:
        rows = self._db.execute("SELECT client, prompt_tokens, completion_tokens, requests, refused FROM usage "
                                "WHERE day = ?", (self.today(),))
        clients = {client: {"prompt_tokens": p, "completion_tokens": c, "requests": r, "refused": f}
                   for client, p, c, r, f in rows}
        routes = {r["prefix"]: {"tokens": self.spent_routed(r["prefix"]), "budget": r["budget"]} for r in ROUTES}
        return {"day": self.today(), "tokens": self.spent(), "budget": DAILY_TOKENS,
                "checks_budget": int(DAILY_TOKENS * CHECKS_SHARE), "clients": clients, "routes": routes}


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


def refusal(client: str, route: dict | None = None) -> str | None:
    """Why this caller can't spend more today, or None."""
    if route:
        if client == CHECKS_CLIENT:
            return "Le modèle renfort est réservé aux messages de l'utilisateur."
        spent = usage.spent_routed(route["prefix"])
        if spent >= route["budget"]:
            return f"Budget du jour du modèle renfort atteint ({spent} tokens sur {route['budget']}). Reprise à minuit."
        return None
    spent = usage.spent()
    if spent >= DAILY_TOKENS:
        return f"Budget du jour atteint ({spent} tokens sur {DAILY_TOKENS}). Reprise à minuit."
    if client == CHECKS_CLIENT and spent >= DAILY_TOKENS * CHECKS_SHARE:
        return "Budget du jour réservé aux messages de l'utilisateur : vérifications automatiques en pause."
    return None


def count(client: str, data: dict, route: dict | None = None) -> None:
    """Adds the usage block of a provider response (or stream chunk), if any."""
    if isinstance(data, dict) and isinstance(data.get("usage"), dict):
        u = data["usage"]
        prompt = int(u.get("prompt_tokens") or u.get("input_tokens") or 0)
        completion = int(u.get("completion_tokens") or u.get("output_tokens") or 0)
        if route:
            usage.add_routed(route["prefix"], client, tokens=prompt + completion)
        else:
            usage.add(client, prompt=prompt, completion=completion)


@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "upstream": UPSTREAM_URL, "keys": sorted(set(KEYS.values())),
            "routes": {r["prefix"]: r["url"] for r in ROUTES}}


@app.get("/usage")
async def get_usage(authorization: str = Header(default="")) -> dict:
    caller(authorization)
    return usage.report()


@app.api_route("/v1/{path:path}", methods=["GET", "POST"])
async def proxy(path: str, request: Request, authorization: str = Header(default="")) -> Response:
    client = caller(authorization)
    body = await request.body()
    payload = None
    if body and request.headers.get("content-type", "").startswith("application/json"):
        try:
            payload = json.loads(body)
        except ValueError:
            payload = None
    route = route_for(payload.get("model")) if isinstance(payload, dict) else None
    if request.method == "POST" and (reason := refusal(client, route)):
        usage.add(client, refused=1)
        log.warning("refused %s: %s", client, reason)
        return JSONResponse({"error": {"message": reason, "type": "insufficient_quota", "code": "daily_budget"}},
                            status_code=429)
    if isinstance(payload, dict) and payload.get("stream"):
        # Without this, providers don't report usage at the end of a stream.
        payload["stream_options"] = {**(payload.get("stream_options") or {}), "include_usage": True}
        body = json.dumps(payload).encode()
    headers = {k: v for k, v in request.headers.items() if k.lower() not in HOP_HEADERS}
    headers["Authorization"] = f"Bearer {route['key'] if route else UPSTREAM_KEY}"
    if request.method == "POST":
        if route:
            usage.add_routed(route["prefix"], client, requests=1)
        else:
            usage.add(client, requests=1)

    base = route["url"] if route else UPSTREAM_URL
    upstream_request = upstream.build_request(request.method, f"{base}/{path}", content=body or None,
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
                            count(client, json.loads(line[5:].strip()), route)
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
            count(client, json.loads(content), route)
        except ValueError:
            pass
    return Response(content, status_code=resp.status_code, headers=out_headers)
