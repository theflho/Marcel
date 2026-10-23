"""Marcel backend: the only thing the iPhone talks to.

The iPhone sends chat messages here; this service forwards them to Hermes on the
internal Docker network and relays the answer as Server-Sent Events. Hermes and
Scaleway credentials live only in this container's environment.
"""

import asyncio
import base64
import json
import logging
import os
import secrets
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Literal

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, UploadFile
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

MARCEL_TOKEN = os.environ.get("MARCEL_TOKEN", "")
HERMES_URL = os.environ.get("HERMES_URL", "http://hermes:8642").rstrip("/")
HERMES_API_KEY = os.environ.get("HERMES_API_KEY", "")
HERMES_MODEL = os.environ.get("HERMES_MODEL", "hermes-agent")
MOCK = os.environ.get("MARCEL_MOCK") == "1"
FILES_DIR = Path(os.environ.get("MARCEL_DATA_DIR", "/data")) / "files"
MAX_UPLOAD_BYTES = 20 * 1024 * 1024
# Text extracted from a document and passed to Hermes is capped to keep prompts sane.
MAX_EXTRACTED_CHARS = 20_000
TEXT_MIME_PREFIXES = ("text/", "application/json", "application/xml")

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
    attachments: list[str] = Field(default_factory=list, max_length=10)


class ChatRequest(BaseModel):
    conversation_id: str
    messages: list[Message] = Field(min_length=1, max_length=200)


def sse(payload: dict) -> str:
    return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"


@app.get("/health", dependencies=[Depends(require_token)])
async def health() -> dict:
    return {"status": "ok", "mock": MOCK}


@app.post("/v1/files", dependencies=[Depends(require_token)])
async def upload_file(file: UploadFile) -> dict:
    """Stores one attachment on the VPS and returns the id the app sends with its message."""
    FILES_DIR.mkdir(parents=True, exist_ok=True)
    file_id = secrets.token_hex(16)
    path = FILES_DIR / file_id
    size = 0
    with path.open("wb") as out:
        while chunk := await file.read(1024 * 1024):
            size += len(chunk)
            if size > MAX_UPLOAD_BYTES:
                out.close()
                path.unlink(missing_ok=True)
                raise HTTPException(413, "Fichier trop volumineux (20 Mo maximum)")
            out.write(chunk)
    meta = {
        "id": file_id,
        "filename": Path(file.filename or "fichier").name,
        "mime_type": file.content_type or "application/octet-stream",
        "size": size,
    }
    (FILES_DIR / f"{file_id}.json").write_text(json.dumps(meta))
    return meta


def load_file(file_id: str) -> tuple[dict, bytes]:
    if len(file_id) != 32 or any(c not in "0123456789abcdef" for c in file_id):
        raise HTTPException(400, "Identifiant de fichier invalide")
    try:
        meta = json.loads((FILES_DIR / f"{file_id}.json").read_text())
        return meta, (FILES_DIR / file_id).read_bytes()
    except FileNotFoundError:
        raise HTTPException(404, "Pièce jointe introuvable") from None


def extract_text(meta: dict, data: bytes) -> str | None:
    """Readable text of a document, or None when it can't be read."""
    mime = meta["mime_type"]
    if mime.startswith(TEXT_MIME_PREFIXES):
        return data.decode("utf-8", errors="replace")[:MAX_EXTRACTED_CHARS]
    if mime == "application/pdf":
        from io import BytesIO

        from pypdf import PdfReader

        try:
            reader = PdfReader(BytesIO(data))
            text = "\n".join(page.extract_text() or "" for page in reader.pages)
        except Exception:
            log.warning("PDF extraction failed for %s", meta["id"])
            return None
        return text[:MAX_EXTRACTED_CHARS] or None
    return None


def hermes_content(message: Message) -> str | list[dict]:
    """OpenAI-style content: plain text, or parts when attachments are present.

    Photos go as images (the model must support vision); documents go as extracted text.
    """
    if not message.attachments:
        return message.content
    parts: list[dict] = [{"type": "text", "text": message.content}] if message.content else []
    for file_id in message.attachments:
        meta, data = load_file(file_id)
        if meta["mime_type"].startswith("image/"):
            encoded = base64.b64encode(data).decode()
            parts.append({"type": "image_url", "image_url": {"url": f"data:{meta['mime_type']};base64,{encoded}"}})
        elif (text := extract_text(meta, data)) is not None:
            parts.append({"type": "text", "text": f"--- Fichier joint : {meta['filename']} ---\n{text}"})
        else:
            parts.append({"type": "text", "text": f"[Fichier joint non lisible : {meta['filename']} ({meta['mime_type']})]"})
    return parts


@app.post("/v1/chat/stream", dependencies=[Depends(require_token)])
async def chat_stream(request: ChatRequest) -> StreamingResponse:
    for message in request.messages:
        for file_id in message.attachments:
            load_file(file_id)  # fail fast with 404 before streaming starts
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
        "messages": [{"role": m.role, "content": hermes_content(m)} for m in request.messages],
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
    if files := request.messages[-1].attachments:
        names = []
        for file_id in files:
            meta, data = load_file(file_id)
            readable = meta["mime_type"].startswith("image/") or extract_text(meta, data) is not None
            names.append(f"- **{meta['filename']}** ({meta['size'] // 1024} Ko, {'lisible' if readable else 'non lisible'})")
        reply = "J'ai bien reçu tes pièces jointes :\n\n" + "\n".join(names)
        if last:
            reply += f"\n\nEt ton message : *{last}*"
        for word in reply.split(" "):
            await asyncio.sleep(0.03)
            yield word + " "
        return
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
