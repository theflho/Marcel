"""Marcel backend: the only thing the iPhone talks to.

The iPhone sends chat messages here; this service forwards them to Hermes on the
internal Docker network and relays the answer as Server-Sent Events. Hermes and
Scaleway credentials live only in this container's environment.
"""

import asyncio
import json
import logging
import os
import secrets
from collections.abc import AsyncIterator
from typing import Literal

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

MARCEL_TOKEN = os.environ.get("MARCEL_TOKEN", "")
HERMES_URL = os.environ.get("HERMES_URL", "http://hermes:8642").rstrip("/")
HERMES_API_KEY = os.environ.get("HERMES_API_KEY", "")
HERMES_MODEL = os.environ.get("HERMES_MODEL", "hermes-agent")
MOCK = os.environ.get("MARCEL_MOCK") == "1"

log = logging.getLogger("marcel")
app = FastAPI(title="Marcel", docs_url=None, redoc_url=None, openapi_url=None)


def require_token(authorization: str = Header(default="")) -> None:
    if not MARCEL_TOKEN:
        raise HTTPException(503, "MARCEL_TOKEN is not configured")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not secrets.compare_digest(token, MARCEL_TOKEN):
        raise HTTPException(401, "Invalid token")


class Message(BaseModel):
    role: Literal["user", "assistant"]
    content: str = Field(max_length=100_000)


class ChatRequest(BaseModel):
    conversation_id: str
    messages: list[Message] = Field(min_length=1, max_length=200)


def sse(payload: dict) -> str:
    return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"


@app.get("/health", dependencies=[Depends(require_token)])
async def health() -> dict:
    return {"status": "ok", "mock": MOCK}


@app.post("/v1/chat/stream", dependencies=[Depends(require_token)])
async def chat_stream(request: ChatRequest) -> StreamingResponse:
    source = mock_stream(request) if MOCK else hermes_stream(request)

    async def events() -> AsyncIterator[str]:
        try:
            async for text in source:
                yield sse({"type": "delta", "text": text})
            yield sse({"type": "done"})
        except Exception:
            log.exception("chat stream failed")
            yield sse({"type": "error", "message": "Hermes n'a pas pu répondre."})

    return StreamingResponse(
        events(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


async def hermes_stream(request: ChatRequest) -> AsyncIterator[str]:
    """Calls Hermes' OpenAI-compatible endpoint and yields text deltas."""
    headers = {"Authorization": f"Bearer {HERMES_API_KEY}"} if HERMES_API_KEY else {}
    body = {
        "model": HERMES_MODEL,
        "stream": True,
        "messages": [m.model_dump() for m in request.messages],
        "user": request.conversation_id,
    }
    timeout = httpx.Timeout(connect=10, read=300, write=30, pool=10)
    async with httpx.AsyncClient(timeout=timeout) as client:
        async with client.stream("POST", f"{HERMES_URL}/v1/chat/completions", json=body, headers=headers) as resp:
            resp.raise_for_status()
            async for line in resp.aiter_lines():
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                chunk = json.loads(data)
                for choice in chunk.get("choices", []):
                    if text := (choice.get("delta") or {}).get("content"):
                        yield text


async def mock_stream(request: ChatRequest) -> AsyncIterator[str]:
    """Local stand-in for Hermes, to test the app without the VPS."""
    last = request.messages[-1].content
    if "markdown" in last.lower():
        for chunk in MARKDOWN_DEMO.split(" "):
            await asyncio.sleep(0.02)
            yield chunk + " "
        return
    reply = (
        f"Bien reçu : *{last}*.\n\n"
        "Je suis le **backend de test** de Marcel. Cette réponse arrive mot par mot "
        "pour vérifier le `streaming` de bout en bout."
    )
    for word in reply.split(" "):
        await asyncio.sleep(0.06)
        yield word + " "


MARKDOWN_DEMO = """## Plan de la semaine

Voici ce que je propose, **par priorité** :

1. Finir le *formulaire* de sortie
2. Répondre à `Jean` avant jeudi
3. Réserver le restaurant

- Penser au pique-nique
- Vérifier la météo

> Rappel : rien n'est envoyé sans ton accord.

| Jour | Tâche | Statut |
|------|-------|--------|
| Lundi | Formulaire | Fait |
| Jeudi | Sortie | À venir |

```python
def bonjour():
    print("Salut Marcel")
```

---

Dis-moi si je lance la première mission."""
