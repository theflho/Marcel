"""Marcel backend: the only thing the iPhone talks to.

The iPhone starts a mission here; this service asks Hermes on the internal Docker
network for the answer and keeps it, so the mission continues when the app is closed.
The app follows the answer as Server-Sent Events and can reconnect at any time.
Hermes and Scaleway credentials live only in this container's environment.
"""

import asyncio
import base64
import json
import logging
import os
import re
import secrets
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, Query, UploadFile
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from .goals import ACTIVE, GoalStore
from .memory import ARCHIVE, CORE, DAY, MemoryStore, split_entries
from .missions import DONE, MissionStore, valid_id
from .proactive import (DISMISSED, FAILED, LATER, NOTHING, NOTIFY, OPENED, IdeaStore, in_hours, is_due,
                        parse_hours)

MARCEL_TOKEN = os.environ.get("MARCEL_TOKEN", "")
HERMES_URL = os.environ.get("HERMES_URL", "http://hermes:8642").rstrip("/")
HERMES_API_KEY = os.environ.get("HERMES_API_KEY", "")
HERMES_MODEL = os.environ.get("HERMES_MODEL", "hermes-agent")
MOCK = os.environ.get("MARCEL_MOCK") == "1"


def parse_models(raw: str) -> list[dict]:
    """MARCEL_MODELS="id=Label,id2=Label 2" → [{"id", "label"}]; the first one is the default."""
    models = []
    for item in filter(None, (part.strip() for part in raw.split(","))):
        model_id, _, label = item.partition("=")
        models.append({"id": model_id.strip(), "label": (label or model_id).strip()})
    return models


# Readable names for model ids: "deepseek-r1-distill-llama-70b" → "DeepSeek R1 Distill Llama 70B".
MODEL_WORDS = {"deepseek": "DeepSeek", "llama": "Llama", "qwen": "Qwen", "mistral": "Mistral", "gpt": "GPT",
               "gemma": "Gemma", "pixtral": "Pixtral", "instruct": "Instruct", "chat": "Chat"}


def model_label(model_id: str) -> str:
    words = []
    for part in re.split(r"[-_]", model_id.rsplit("/", 1)[-1]):
        lower = part.lower()
        if lower in MODEL_WORDS:
            words.append(MODEL_WORDS[lower])
        elif re.fullmatch(r"[a-z]?\d+(\.\d+)?[a-z]?", lower):
            words.append(part.upper())
        elif part:
            words.append(part.capitalize())
    return " ".join(words) or model_id


# MARCEL_MODELS overrides the list; otherwise it is read from Hermes (`GET /v1/models`).
MODELS_OVERRIDE = parse_models(os.environ.get("MARCEL_MODELS", ""))
MOCK_MODELS = [{"id": "deepseek-r1-distill-llama-70b", "label": "DeepSeek R1 Distill Llama 70B"},
               {"id": "deepseek-v3", "label": "DeepSeek V3"}]
MODELS_CACHE_SECONDS = 300
_models_cache: tuple[float, list[dict]] = (0.0, [])


async def available_models() -> list[dict]:
    """Models offered in the app; the first one is the default."""
    global _models_cache
    if MODELS_OVERRIDE:
        return MODELS_OVERRIDE
    if MOCK:
        return MOCK_MODELS
    fetched_at, cached = _models_cache
    if cached and time.monotonic() - fetched_at < MODELS_CACHE_SECONDS:
        return cached
    headers = {"Authorization": f"Bearer {HERMES_API_KEY}"} if HERMES_API_KEY else {}
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            resp = await client.get(f"{HERMES_URL}/v1/models", headers=headers)
            resp.raise_for_status()
            ids = [item["id"] for item in resp.json().get("data", []) if item.get("id")]
    except Exception:
        log.warning("could not list Hermes models, using HERMES_MODEL")
        ids = []
    # HERMES_MODEL stays the default when Hermes lists it (or lists nothing).
    ids = sorted(set(ids), key=lambda i: (i != HERMES_MODEL, i)) or [HERMES_MODEL]
    models = [{"id": i, "label": model_label(i)} for i in ids]
    _models_cache = (time.monotonic(), models)
    return models
DATA_DIR = Path(os.environ.get("MARCEL_DATA_DIR", "/data"))
FILES_DIR = DATA_DIR / "files"
MAX_UPLOAD_BYTES = 20 * 1024 * 1024
# Text extracted from a document and passed to Hermes is capped to keep prompts sane.
MAX_EXTRACTED_CHARS = 20_000
TEXT_MIME_PREFIXES = ("text/", "application/json", "application/xml")

# Memory: the core is sent with every mission, so it has a character budget.
MEMORY_CORE_CHARS = int(os.environ.get("MARCEL_MEMORY_CORE_CHARS") or 1500)
# Hour (server local time) of the nightly tidying.
MEMORY_TIDY_HOUR = int(os.environ.get("MARCEL_MEMORY_TIDY_HOUR") or 3)
# Model used to extract and tidy memories (OpenAI-compatible). Defaults to Hermes; pointing it
# straight at the model provider avoids running the whole agent for these small jobs.
MEMORY_LLM_URL = (os.environ.get("MARCEL_MEMORY_LLM_URL") or HERMES_URL).rstrip("/")
MEMORY_LLM_KEY = (os.environ.get("MARCEL_MEMORY_LLM_KEY") or HERMES_API_KEY)
MEMORY_LLM_MODEL = (os.environ.get("MARCEL_MEMORY_LLM_MODEL") or HERMES_MODEL)
# Proactive checks: how often the scheduler looks for due goals, during which hours, and the
# default cost ceiling (checks per day, editable in the app).
PROACTIVE_TICK = int(os.environ.get("MARCEL_PROACTIVE_TICK_SECONDS") or 900)
PROACTIVE_HOURS = parse_hours(os.environ.get("MARCEL_PROACTIVE_HOURS") or "8-21")
PROACTIVE_MAX_CHECKS = int(os.environ.get("MARCEL_PROACTIVE_MAX_CHECKS") or 6)
# Checks can go to a second Hermes profile whose tools can't act outside (no terminal, browser,
# messaging…): the real guarantee that a check only looks and prepares. Defaults to Hermes.
CHECK_HERMES_URL = (os.environ.get("MARCEL_CHECK_HERMES_URL") or HERMES_URL).rstrip("/")
CHECK_HERMES_KEY = os.environ.get("MARCEL_CHECK_HERMES_KEY") or (HERMES_API_KEY if CHECK_HERMES_URL == HERMES_URL else "")
CHECK_HERMES_MODEL = os.environ.get("MARCEL_CHECK_HERMES_MODEL", "")

log = logging.getLogger("marcel")
missions = MissionStore(DATA_DIR / "marcel.db")
memory = MemoryStore(DATA_DIR / "marcel.db", core_budget=MEMORY_CORE_CHARS)
goals = GoalStore(DATA_DIR / "marcel.db")
ideas = IdeaStore(DATA_DIR / "marcel.db", max_checks_per_day=PROACTIVE_MAX_CHECKS)
# Background jobs (memory extraction) are kept here so they aren't garbage-collected mid-way.
background: set[asyncio.Task] = set()


def spawn(coro) -> asyncio.Task:
    task = asyncio.create_task(coro)
    background.add(task)
    task.add_done_callback(background.discard)
    return task


@asynccontextmanager
async def lifespan(_: FastAPI):
    jobs = [asyncio.create_task(nightly_tidy()), asyncio.create_task(proactive_loop())]
    yield
    for job in jobs:
        job.cancel()
    await missions.shutdown()


app = FastAPI(title="Marcel", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)


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
    model: str | None = None


def sse(payload: dict) -> str:
    return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"


@app.get("/health", dependencies=[Depends(require_token)])
async def health() -> dict:
    return {"status": "ok", "mock": MOCK, "emergency": missions.emergency, "ideas": ideas.unseen()}


@app.get("/v1/models", dependencies=[Depends(require_token)])
async def list_models() -> dict:
    models = await available_models()
    return {"models": models, "default": models[0]["id"]}


@app.get("/v1/emergency", dependencies=[Depends(require_token)])
async def emergency_state() -> dict:
    return {"active": missions.emergency}


@app.post("/v1/emergency/stop", dependencies=[Depends(require_token)])
async def emergency_stop() -> dict:
    """Cuts every running mission and refuses new ones: nothing reaches Hermes until resumed."""
    stopped = await missions.emergency_stop()
    log.warning("emergency stop: %d mission(s) cut", stopped)
    return {"active": True, "stopped": stopped}


@app.post("/v1/emergency/resume", dependencies=[Depends(require_token)])
async def emergency_resume() -> dict:
    missions.emergency_resume()
    return {"active": False}


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


@app.post("/v1/missions", dependencies=[Depends(require_token)])
async def start_mission(request: ChatRequest) -> dict:
    """Starts generating the reply on the server and returns at once."""
    for message in request.messages:
        for file_id in message.attachments:
            load_file(file_id)  # fail fast with 404 before the mission starts
    if missions.emergency:
        raise HTTPException(423, "Arrêt d'urgence actif : aucune mission ne peut démarrer.")
    if missions.running_count() >= missions.max_running:
        raise HTTPException(429, "Trop de missions en cours, réessaie dans un instant.")
    models = await available_models()
    model = request.model or models[0]["id"]
    if model not in {m["id"] for m in models}:
        raise HTTPException(400, "Modèle inconnu")
    title = next((m.content for m in reversed(request.messages) if m.role == "user"), "")
    note, facts = memory.context(title)
    note = "\n\n".join(filter(None, [note, goals.context()]))
    inner = (lambda: mock_stream(request, facts)) if MOCK else (lambda: hermes_stream(request, model, note))
    return missions.start(request.conversation_id, lambda: with_memory(request, inner, facts),
                          model=model, title=title).public()


async def with_memory(request: ChatRequest, inner, facts) -> AsyncIterator[str | dict]:
    """Shows which memories were sent, then, once the reply is complete, learns from the exchange."""
    if facts:
        core = sum(1 for f in facts if f.tier == CORE)
        detail = f"{core} du noyau, {len(facts) - core} des archives : " + " · ".join(f.text for f in facts)
        yield {"id": "memory", "name": "Mémoire", "detail": detail[:300], "status": "done"}
    reply = []
    async for item in inner():
        if isinstance(item, str):
            reply.append(item)
        yield item
    # Only reached when the mission completed: a stopped reply teaches nothing.
    spawn(remember(request, "".join(reply)))


@app.get("/v1/missions", dependencies=[Depends(require_token)])
async def list_missions(conversation_id: str | None = None, active: bool = False) -> list[dict]:
    return [m.public() for m in missions.list(conversation_id, active_only=active)]


def find_mission(mission_id: str):
    if not valid_id(mission_id) or not (mission := missions.get(mission_id)):
        raise HTTPException(404, "Mission introuvable")
    return mission


@app.get("/v1/missions/{mission_id}", dependencies=[Depends(require_token)])
async def get_mission(mission_id: str) -> dict:
    mission = find_mission(mission_id)
    return mission.public() | {"text": mission.text}


@app.get("/v1/missions/{mission_id}/events", dependencies=[Depends(require_token)])
async def mission_events(mission_id: str, offset: int = Query(default=0, ge=0)) -> StreamingResponse:
    """The reply from `offset` (in Unicode code points), then live until the mission ends."""
    mission = find_mission(mission_id)

    async def events() -> AsyncIterator[str]:
        async for event in missions.follow(mission, offset):
            yield ": ping\n\n" if event is None else sse(event)

    return StreamingResponse(
        events(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.post("/v1/missions/{mission_id}/cancel", dependencies=[Depends(require_token)])
async def cancel_mission(mission_id: str) -> dict:
    mission = find_mission(mission_id)
    missions.cancel(mission)
    if mission.task:
        await asyncio.gather(mission.task, return_exceptions=True)
    return mission.public()


async def hermes_stream(request: ChatRequest, model: str, memory_note: str = "",
                        url: str = HERMES_URL, key: str = HERMES_API_KEY) -> AsyncIterator[str | dict]:
    """Calls Hermes' OpenAI-compatible endpoint and yields text deltas.

    Tool calls streamed by Hermes become actions, so the app can show what the agent does.
    """
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    body = {
        "model": model,
        "stream": True,
        "messages": ([{"role": "system", "content": memory_note}] if memory_note else [])
        + [{"role": m.role, "content": hermes_content(m)} for m in request.messages],
        "user": request.conversation_id,
    }
    tools: dict[int, dict] = {}

    def finish_tools() -> list[dict]:
        done = [{"id": t["id"], "status": "done"} for t in tools.values() if t["status"] == "running"]
        for tool in tools.values():
            tool["status"] = "done"
        return done

    timeout = httpx.Timeout(connect=10, read=300, write=30, pool=10)
    async with httpx.AsyncClient(timeout=timeout) as client:
        async with client.stream("POST", f"{url}/v1/chat/completions", json=body, headers=headers) as resp:
            resp.raise_for_status()
            async for line in resp.aiter_lines():
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                chunk = json.loads(data)
                for choice in chunk.get("choices", []):
                    delta = choice.get("delta") or {}
                    for call in delta.get("tool_calls") or []:
                        index = call.get("index", 0)
                        function = call.get("function") or {}
                        tool = tools.setdefault(index, {"id": call.get("id") or f"tool-{index}", "name": "",
                                                        "detail": "", "status": "running"})
                        tool["name"] += function.get("name") or ""
                        tool["detail"] = (tool["detail"] + (function.get("arguments") or ""))[:300]
                        yield dict(tool)
                    if text := delta.get("content"):
                        for update in finish_tools():
                            yield update
                        yield text
                    if choice.get("finish_reason"):
                        for update in finish_tools():
                            yield update


async def mock_stream(request: ChatRequest, facts=()) -> AsyncIterator[str | dict]:
    """Local stand-in for Hermes, to test the app without the VPS."""
    last = request.messages[-1].content
    if re.search(r"souviens|m[ée]moire|sais de moi", last.lower()):
        reply = ("Voici ce qu'on m'a transmis de ta mémoire pour cette question :\n\n"
                 + "\n".join(f"- {f.text} *({'noyau' if f.tier == CORE else 'archives'})*" for f in facts)
                 if facts else "Je n'ai reçu aucun souvenir lié à cette question.")
        for word in reply.split(" "):
            await asyncio.sleep(0.03)
            yield word + " "
        return
    if re.search(r"objectif", last.lower()):
        followed = goals.list(ACTIVE)
        reply = ("Les objectifs que je suis pour toi :\n\n" + "\n".join(f"- {g.title}" for g in followed)
                 if followed else "Je ne suis aucun objectif pour l'instant.")
        for word in reply.split(" "):
            await asyncio.sleep(0.03)
            yield word + " "
        return
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
    if "mission" in last.lower():
        # A slow reply (about 20 s) with agent steps, to test closing the app while Marcel works.
        steps = [
            ("Bash", "ls ~/projets/marcel"),
            ("Lecture", "README.md"),
            ("Bash", "git status --short"),
            ("Recherche", "missions côté serveur"),
            ("Bash", "pytest -q"),
            ("Écriture", "rapport.md"),
            ("Bash", "tailscale status"),
            ("Envoi", "résumé à Théo"),
        ]
        for index, (name, detail) in enumerate(steps, start=1):
            yield {"id": f"step-{index}", "name": name, "detail": detail, "status": "running"}
            await asyncio.sleep(2.5)
            yield {"id": f"step-{index}", "status": "done"}
            yield f"{'' if index == 1 else chr(10)}{index}. Étape {index} sur {len(steps)} terminée ({name.lower()})."
        model = request.model or MOCK_MODELS[0]["id"]
        yield f"\n\n**Mission terminée** avec `{model}`, même si l'app était fermée."
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


# MARK: Memory


class MemoryCreate(BaseModel):
    text: str = Field(min_length=2, max_length=300)
    tier: Literal["core", "archive"] = ARCHIVE
    importance: int = Field(default=3, ge=1, le=5)
    pinned: bool = False


class MemoryUpdate(BaseModel):
    text: str | None = Field(default=None, min_length=2, max_length=300)
    tier: Literal["core", "archive"] | None = None
    importance: int | None = Field(default=None, ge=1, le=5)
    pinned: bool | None = None


class MemoryImport(BaseModel):
    text: str = Field(max_length=200_000)
    tier: Literal["core", "archive"] = ARCHIVE


def find_fact(fact_id: str):
    if not re.fullmatch(r"[0-9a-f]{12}", fact_id) or not (fact := memory.get(fact_id)) or fact.status != "active":
        raise HTTPException(404, "Souvenir introuvable")
    return fact


@app.get("/v1/memory", dependencies=[Depends(require_token)])
async def list_memory(q: str | None = None, tier: Literal["core", "archive"] | None = None) -> dict:
    facts = memory.search(q, limit=100, tier=tier) if q else memory.active(tier)
    return {"stats": memory.stats(), "items": [f.public() for f in facts]}


@app.post("/v1/memory", dependencies=[Depends(require_token)])
async def add_memory(body: MemoryCreate) -> dict:
    fact = memory.add(body.text, tier=body.tier, importance=body.importance, pinned=body.pinned,
                      source="manuel", reason="ajouté à la main")
    return fact.public()


@app.patch("/v1/memory/{fact_id}", dependencies=[Depends(require_token)])
async def update_memory(fact_id: str, body: MemoryUpdate) -> dict:
    find_fact(fact_id)
    return memory.update(fact_id, reason="modifié à la main", **body.model_dump(exclude_unset=True)).public()


@app.delete("/v1/memory/{fact_id}", dependencies=[Depends(require_token)])
async def delete_memory(fact_id: str) -> dict:
    find_fact(fact_id)
    return memory.delete(fact_id).public()


@app.get("/v1/memory/log", dependencies=[Depends(require_token)])
async def memory_log(limit: int = Query(default=100, ge=1, le=500)) -> list[dict]:
    return memory.log(limit)


@app.post("/v1/memory/log/{entry_id}/undo", dependencies=[Depends(require_token)])
async def undo_memory(entry_id: int) -> dict:
    try:
        undone = memory.undo(entry_id)
    except KeyError:
        raise HTTPException(404, "Entrée introuvable") from None
    return {"undone": undone, "stats": memory.stats()}


@app.post("/v1/memory/tidy", dependencies=[Depends(require_token)])
async def tidy_memory() -> dict:
    if missions.emergency:
        raise HTTPException(423, "Arrêt d'urgence actif : le rangement est suspendu.")
    return await run_tidy()


@app.post("/v1/memory/import", dependencies=[Depends(require_token)])
async def import_memory(body: MemoryImport) -> dict:
    """Moves entries of another memory (Hermes' MEMORY.md, a note…) into Marcel's."""
    batch = f"import-{int(time.time())}"
    entries = split_entries(body.text)
    for entry in entries:
        memory.add(entry, tier=body.tier, source="import", reason="importé", batch=batch)
    return {"imported": len(entries), "batch": batch, "stats": memory.stats()}


EXTRACT_PROMPT = """Tu tiens la mémoire à long terme de Marcel, l'assistant personnel de l'utilisateur.
À partir du dernier échange, retiens seulement les faits durables qui serviront plus tard sur
l'utilisateur : identité, préférences, habitudes, projets et objectifs en cours, contraintes,
proches. Ignore le contenu de la tâche elle-même, les politesses et ce qui ne servira plus.
Une phrase courte par fait (200 caractères max), à la troisième personne (« L'utilisateur… »).
Si un fait connu est précisé, mets-le à jour par son id ; s'il est contredit ou n'est plus vrai,
expire-le. Pour un fait temporaire (achat en cours, voyage prévu), donne une durée de vie en jours.
Importance de 1 (anecdotique) à 5 (essentiel).
Si l'utilisateur exprime un objectif qui se poursuit dans le temps et que Marcel pourrait suivre
pour lui (chercher un achat, apprendre quelque chose, préparer un événement, surveiller une
situation), propose-le dans "goals" : un titre court à l'infinitif (« Trouver un Mac mini »), un
détail utile (budget, contrainte, échéance) et un rythme de vérification : "daily" si ça bouge
vite (prix, disponibilité), "weekly" sinon, "manual" si rien n'est à surveiller. Ne propose pas
une tâche déjà faite dans l'échange, ni un objectif déjà connu. En cas de doute, n'en propose pas.
Réponds uniquement en JSON :
{"add": [{"text": "...", "importance": 3, "expires_days": null}], "update": [{"id": "...", "text": "..."}], "expire": ["id"],
 "goals": [{"title": "...", "detail": "...", "cadence": "weekly"}]}
Rien à retenir : {"add": [], "update": [], "expire": [], "goals": []}"""

TIDY_PROMPT = """Tu ranges la mémoire de Marcel, l'assistant personnel de l'utilisateur.
Repère les faits qui disent la même chose (à fusionner en une phrase courte qui garde tout ce qui
compte) et ceux qui sont contredits par un fait plus récent ou visiblement périmés (à expirer).
Ne touche pas au reste. Réponds uniquement en JSON :
{"merge": [{"ids": ["...", "..."], "text": "..."}], "expire": ["id"]}"""


async def llm_json(system: str, user: str) -> dict:
    """Asks the memory model for a JSON answer."""
    headers = {"Authorization": f"Bearer {MEMORY_LLM_KEY}"} if MEMORY_LLM_KEY else {}
    body = {"model": MEMORY_LLM_MODEL, "temperature": 0, "stream": False,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}
    async with httpx.AsyncClient(timeout=httpx.Timeout(120, connect=10)) as client:
        resp = await client.post(f"{MEMORY_LLM_URL}/v1/chat/completions", json=body, headers=headers)
        resp.raise_for_status()
        content = resp.json()["choices"][0]["message"]["content"] or ""
    # Reasoning models (DeepSeek R1) think out loud first.
    content = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL)
    start, end = content.find("{"), content.rfind("}")
    if start < 0 or end < start:
        raise ValueError("no JSON in the memory model's answer")
    return json.loads(content[start:end + 1])


def mock_facts(text: str) -> list[dict]:
    """Without a model: sentences where the user talks about themself."""
    facts = []
    for sentence in re.split(r"(?<=[.!?])\s+|\n+", text):
        sentence = sentence.strip(" .!?")
        lower = sentence.lower()
        if len(sentence) < 8 or not re.match(r"(je |j'|j’|mon |ma |mes |moi )", lower):
            continue
        temporary = re.search(r"cherche|en ce moment|cette semaine|ce mois|bientôt|prévu", lower)
        lasting = re.search(r"toujours|jamais|préfère|aime|déteste|allergique", lower)
        facts.append({"text": f"L'utilisateur a dit : « {sentence[0].upper()}{sentence[1:]} »",
                      "importance": 4 if lasting else 3, "expires_days": 90 if temporary else None})
    return facts


GOAL_VERBS = {"cherche": "Trouver", "recherche": "Trouver", "prépare": "Préparer", "veux": "", "voudrais": "",
              "aimerais": "", "compte": "", "dois": "", "essaie de": "", "essaye de": ""}


def mock_goals(text: str) -> list[dict]:
    """Without a model: "je cherche un Mac mini, mais…" → "Trouver un Mac mini"."""
    found = []
    for sentence in re.split(r"(?<=[.!?])\s+|\n+", text):
        verbs = "|".join(GOAL_VERBS)
        if not (match := re.search(rf"\b(?:je|j'|j’)\s*({verbs})\s+(.+)", sentence, flags=re.IGNORECASE)):
            continue
        verb, rest = match.group(1).lower(), re.split(r",|\bmais\b|\bet je\b", match.group(2))[0].strip(" .!?")
        if len(rest) < 3:
            continue
        title = f"{GOAL_VERBS[verb]} {rest}".strip() if GOAL_VERBS[verb] else rest
        found.append({"title": title[0].upper() + title[1:], "detail": sentence.strip()[:200],
                      "cadence": "daily" if GOAL_VERBS[verb] == "Trouver" else "weekly"})
    return found


async def remember(request: ChatRequest, reply: str) -> None:
    """Learns durable facts from the last exchange (runs after the mission, in the background)."""
    question = next((m.content for m in reversed(request.messages) if m.role == "user"), "")
    if missions.emergency or not question.strip():
        return
    try:
        if MOCK:
            result = {"add": mock_facts(question), "update": [], "expire": [], "goals": mock_goals(question)}
        else:
            known = memory.search(question + " " + reply[:1000], limit=15)
            known_goals = [g.title for g in goals.list()]
            user = ("Faits déjà connus :\n" + ("\n".join(f"[{f.id}] {f.text}" for f in known) or "(aucun)")
                    + "\n\nObjectifs déjà connus :\n" + ("\n".join(f"- {t}" for t in known_goals) or "(aucun)")
                    + f"\n\nMessage de l'utilisateur :\n{question[:4000]}\n\nRéponse de Marcel :\n{reply[:3000]}")
            result = await llm_json(EXTRACT_PROMPT, user)
        now = time.time()
        for item in result.get("add") or []:
            if isinstance(item, dict) and str(item.get("text", "")).strip():
                days = item.get("expires_days")
                memory.add(str(item["text"]), importance=int(item.get("importance") or 3),
                           source=request.conversation_id, reason="appris dans une conversation",
                           expires_at=now + float(days) * DAY if isinstance(days, (int, float)) and days > 0 else None)
        for item in result.get("update") or []:
            fact = isinstance(item, dict) and memory.get(str(item.get("id")))
            if fact and fact.status == "active" and str(item.get("text", "")).strip():
                memory.update(fact.id, text=str(item["text"]), reason="précisé dans une conversation")
        for fact_id in result.get("expire") or []:
            if (fact := memory.get(str(fact_id))) and fact.status == "active" and not fact.pinned:
                memory.update(fact.id, status="expired", reason="contredit dans une conversation")
        for item in result.get("goals") or []:
            if isinstance(item, dict) and str(item.get("title", "")).strip():
                goals.propose(str(item["title"]), str(item.get("detail") or ""),
                              str(item.get("cadence") or "weekly"), request.conversation_id)
    except Exception:
        log.exception("memory extraction failed")


async def run_tidy() -> dict:
    merges, expire = [], []
    if not MOCK:
        facts = memory.active()[:150]
        if len(facts) >= 2:
            listing = "\n".join(
                f"[{f.id}] ({'noyau' if f.tier == CORE else 'archives'}, {time.strftime('%Y-%m-%d', time.localtime(f.updated_at))}) {f.text}"
                for f in facts)
            try:
                result = await llm_json(TIDY_PROMPT, listing)
                merges = [m for m in result.get("merge") or [] if isinstance(m, dict)]
                expire = [str(i) for i in result.get("expire") or []]
            except Exception:
                log.exception("memory tidying by the model failed, applying the rules only")
    return memory.tidy(merges, expire)


async def nightly_tidy() -> None:
    while True:
        now = time.localtime()
        target = time.mktime((now.tm_year, now.tm_mon, now.tm_mday, MEMORY_TIDY_HOUR, 0, 0, 0, 0, -1))
        if target <= time.time():
            target += DAY
        await asyncio.sleep(target - time.time())
        if missions.emergency:
            continue
        try:
            summary = await run_tidy()
            log.info("memory tidied: %s", {k: v for k, v in summary.items() if k != "stats"})
        except Exception:
            log.exception("nightly memory tidying failed")


# MARK: Goals


class GoalCreate(BaseModel):
    title: str = Field(min_length=3, max_length=120)
    detail: str = Field(default="", max_length=500)
    cadence: Literal["daily", "weekly", "manual"] = "weekly"


class GoalUpdate(BaseModel):
    title: str | None = Field(default=None, min_length=3, max_length=120)
    detail: str | None = Field(default=None, max_length=500)
    status: Literal["proposed", "active", "paused", "done", "dismissed"] | None = None
    cadence: Literal["daily", "weekly", "manual"] | None = None


def find_goal(goal_id: str):
    if not re.fullmatch(r"[0-9a-f]{12}", goal_id) or not (goal := goals.get(goal_id)):
        raise HTTPException(404, "Objectif introuvable")
    return goal


@app.get("/v1/goals/{goal_id}/checks", dependencies=[Depends(require_token)])
async def goal_checks(goal_id: str) -> list[dict]:
    """The last checks of a goal and what Marcel decided each time."""
    find_goal(goal_id)
    return ideas.checks(goal_id)


@app.post("/v1/goals/{goal_id}/check", dependencies=[Depends(require_token)])
async def check_goal(goal_id: str) -> dict:
    """Checks a goal now, whatever its cadence (it still counts toward the daily ceiling)."""
    goal = find_goal(goal_id)
    if goal.status != ACTIVE:
        raise HTTPException(409, "Seul un objectif suivi peut être vérifié.")
    if refusal := check_refusal(goal):
        raise HTTPException(*refusal)
    mission, _ = await run_check(goal)
    return mission.public()


@app.get("/v1/goals", dependencies=[Depends(require_token)])
async def list_goals(status: Literal["proposed", "active", "paused", "done", "dismissed"] | None = None,
                     conversation_id: str | None = None) -> list[dict]:
    """Every goal except the dismissed ones, or those with `status`."""
    return [g.public() for g in goals.list(status, conversation_id)]


@app.post("/v1/goals", dependencies=[Depends(require_token)])
async def add_goal(body: GoalCreate) -> dict:
    return goals.add(body.title, body.detail, body.cadence).public()


@app.patch("/v1/goals/{goal_id}", dependencies=[Depends(require_token)])
async def update_goal(goal_id: str, body: GoalUpdate) -> dict:
    find_goal(goal_id)
    return goals.update(goal_id, **body.model_dump(exclude_unset=True, exclude_none=True)).public()


@app.delete("/v1/goals/{goal_id}", dependencies=[Depends(require_token)])
async def delete_goal(goal_id: str) -> dict:
    goal = find_goal(goal_id)
    goals.delete(goal_id)
    return goal.public()


# MARK: Proactive Marcel

# Goals being checked right now, so the same goal never runs twice at once.
checking: set[str] = set()

CHECK_PROMPT = """Réponds uniquement en français.
Vérification automatique d'un objectif que l'utilisateur t'a demandé de suivre :
« {title} »{detail}
{notes}
Regarde où ça en est maintenant (nouveautés, prix, disponibilités, dates, étapes suivantes) avec
les outils dont tu disposes, puis écris un compte rendu court et factuel, avec tes sources.
Tu peux PRÉPARER une action utile (brouillon de message, panier, réservation à confirmer), mais
n'effectue aucune action réelle : n'envoie rien, ne réserve rien, n'achète rien, ne publie rien,
ne modifie aucun compte. Toute action attendra la validation de l'utilisateur dans l'app. Ne propose pas de créer
une surveillance ou une tâche planifiée : c'est Marcel qui s'en charge."""

FILTER_PROMPT = """Tu es le filtre de Marcel, l'assistant personnel de l'utilisateur. Une vérification
automatique d'un de ses objectifs vient de se terminer. Décide s'il faut le prévenir :
- "notify" : il y a du nouveau qui mérite vraiment un message maintenant (occasion qui ne durera
  pas, changement important, échéance proche, décision à prendre) ;
- "later" : utile à garder en tête, mais pas encore assez pour le déranger ;
- "nothing" : rien de nouveau par rapport à ce qu'on savait déjà.
Ne le dérange pas pour rien : en cas de doute, choisis "later". Ne reprends pas une idée qu'il a
déjà refusée. "message" s'adresse à lui (tutoiement, 3 phrases maximum, l'essentiel et pourquoi
c'est utile maintenant). "action" décrit en une phrase l'action que Marcel a préparée et qui
attend son accord (« Commander le Mac mini M4 à 599 € chez … »), sinon "". "note" résume en une
phrase ce qu'on sait maintenant, pour la prochaine vérification. Importance de 1 à 5.
Réponds uniquement en JSON :
{"decision": "notify", "title": "...", "message": "...", "action": "", "importance": 3, "note": "..."}"""


def check_refusal(goal, scheduled: bool = False) -> tuple[int, str] | None:
    """Why a check can't start now, as (HTTP status, message), or None."""
    if missions.emergency:
        return 423, "Arrêt d'urgence actif : aucune vérification ne part."
    if goal.id in checking:
        return 409, "Une vérification de cet objectif est déjà en cours."
    # Checks still running count too: they are recorded only once finished.
    if ideas.checks_today() + len(checking) >= ideas.settings()["max_checks_per_day"]:
        return 429, "Plafond de vérifications du jour atteint."
    # Scheduled checks leave a slot free for the user's own missions.
    if missions.running_count() >= missions.max_running - (1 if scheduled else 0):
        return 429, "Trop de missions en cours, réessaie dans un instant."
    return None


async def run_check(goal):
    """Starts a check mission on the goal; returns it with the task that filters its result."""
    checking.add(goal.id)
    goals.mark_run(goal.id, time.time())
    notes = ideas.kept_notes(goal.id)
    prompt = CHECK_PROMPT.format(
        title=goal.title, detail=f"\nDétails : {goal.detail}" if goal.detail else "",
        notes=("\nCe que les vérifications précédentes avaient noté :\n" + "\n".join(f"- {n}" for n in notes) + "\n")
        if notes else "")
    request = ChatRequest(conversation_id=f"goal-{goal.id}", messages=[Message(role="user", content=prompt)])
    note, _ = memory.context(goal.title + " " + goal.detail)
    model = CHECK_HERMES_MODEL or (await available_models())[0]["id"]
    source = ((lambda: mock_check_stream(goal)) if MOCK
              else (lambda: hermes_stream(request, model, note, CHECK_HERMES_URL, CHECK_HERMES_KEY)))
    try:
        mission = missions.start(request.conversation_id, source, model=model, title=f"Vérification : {goal.title}")
    except Exception:
        checking.discard(goal.id)
        raise
    return mission, spawn(finish_check(goal, mission))


async def finish_check(goal, mission) -> None:
    """Once the check is over, lets the model decide whether it is worth an idea."""
    try:
        await asyncio.gather(mission.task, return_exceptions=True)
        if mission.status != DONE or missions.emergency:
            ideas.record_check(goal.id, mission.id, FAILED, mission.error or mission.status)
            return
        try:
            verdict = mock_verdict(goal) if MOCK else await llm_json(FILTER_PROMPT, filter_input(goal, mission.text))
        except Exception:
            log.exception("proactive filter failed for goal %s", goal.id)
            ideas.record_check(goal.id, mission.id, FAILED, "le filtre n'a pas répondu")
            return
        decision, reason = settle(goal, verdict)
        note = str(verdict.get("note") or "").strip()
        if decision == NOTIFY:
            idea = ideas.add(goal.id, goal.title, str(verdict.get("title") or goal.title),
                             str(verdict.get("message") or ""), str(verdict.get("action") or ""),
                             importance(verdict), mission.id)
            log.info("proactive idea %s for goal %s", idea.id, goal.id)
        ideas.record_check(goal.id, mission.id, decision, " — ".join(filter(None, [note, reason])))
    finally:
        checking.discard(goal.id)


def filter_input(goal, report: str) -> str:
    notes = ideas.kept_notes(goal.id)
    refused = ideas.dismissed_titles(goal.id)
    return (f"Objectif : {goal.title}" + (f" ({goal.detail})" if goal.detail else "")
            + "\n\nCe qu'on savait déjà :\n" + ("\n".join(f"- {n}" for n in notes) or "(rien)")
            + "\n\nIdées déjà refusées par l'utilisateur :\n" + ("\n".join(f"- {t}" for t in refused) or "(aucune)")
            + f"\n\nCompte rendu de la vérification :\n{report[:6000]}")


def importance(verdict: dict) -> int:
    try:
        return int(verdict.get("importance") or 3)
    except (TypeError, ValueError):
        return 3


def settle(goal, verdict: dict) -> tuple[str, str]:
    """The model's decision, held back by the proactivity level, the daily limit and duplicates."""
    decision = str(verdict.get("decision") or NOTHING)
    if decision not in (NOTIFY, LATER, NOTHING):
        decision = LATER
    if decision != NOTIFY:
        return decision, ""
    if ideas.settings()["level"] == "off":
        return LATER, "proactivité désactivée"
    if importance(verdict) < ideas.min_importance():
        return LATER, "pas assez important en mode discret"
    if ideas.daily_limit() <= ideas.ideas_today():
        return LATER, "limite d'idées du jour atteinte"
    if ideas.find_similar(goal.id, str(verdict.get("title") or ""), since=time.time() - 7 * DAY):
        return LATER, "idée déjà proposée ou refusée"
    return NOTIFY, ""


async def run_due_checks() -> int:
    """One pass of the scheduler: checks the due goals one after the other. Returns how many ran."""
    if missions.emergency or ideas.settings()["level"] == "off" or not in_hours(PROACTIVE_HOURS, time.time()):
        return 0
    ran = 0
    now = time.time()
    due = [g for g in goals.list(ACTIVE) if is_due(g.cadence, g.last_run_at, now)]
    for goal in sorted(due, key=lambda g: g.last_run_at or 0):
        if refusal := check_refusal(goal, scheduled=True):
            if refusal[0] != 409:
                break
            continue
        _, finished = await run_check(goal)
        await finished
        ran += 1
    return ran


async def proactive_loop() -> None:
    while True:
        await asyncio.sleep(PROACTIVE_TICK)
        try:
            if ran := await run_due_checks():
                log.info("proactive: %d goal check(s)", ran)
        except Exception:
            log.exception("proactive checks failed")


async def mock_check_stream(goal) -> AsyncIterator[str | dict]:
    """Stand-in for a check through Hermes."""
    for index, (name, detail) in enumerate([("Recherche", goal.title), ("Comparaison", "3 sources")], start=1):
        yield {"id": f"check-{index}", "name": name, "detail": detail, "status": "running"}
        await asyncio.sleep(1)
        yield {"id": f"check-{index}", "status": "done"}
    yield f"Compte rendu pour « {goal.title} » : deux nouveautés repérées, sources de test."


def mock_verdict(goal) -> dict:
    """Without a model: the checks of a goal give in turn notify, later, nothing."""
    decision = (NOTIFY, LATER, NOTHING)[len(ideas.checks(goal.id, limit=100)) % 3]
    buying = goal.title.lower().startswith("trouver")
    return {"decision": decision, "title": f"Du nouveau pour « {goal.title} »", "importance": 4,
            "message": f"J'ai vérifié « {goal.title} » : une occasion intéressante vient d'apparaître (réponse de test).",
            "action": "Préparer la commande, à valider dans l'app" if buying else "",
            "note": f"Vérification de test n° {len(ideas.checks(goal.id, limit=100)) + 1}."}


class ProactiveUpdate(BaseModel):
    level: Literal["off", "quiet", "normal"] | None = None
    daily_limit: int | None = Field(default=None, ge=0, le=10)
    max_checks_per_day: int | None = Field(default=None, ge=0, le=50)


class IdeaUpdate(BaseModel):
    status: Literal["seen", "opened", "dismissed"]
    conversation_id: str | None = Field(default=None, max_length=64)


def proactive_state() -> dict:
    return ideas.settings() | {
        "checks_today": ideas.checks_today(), "ideas_today": ideas.ideas_today(),
        "ideas_allowed_today": ideas.daily_limit(), "unseen": ideas.unseen(),
        "hours": list(PROACTIVE_HOURS),
    }


@app.get("/v1/proactive", dependencies=[Depends(require_token)])
async def get_proactive() -> dict:
    return proactive_state()


@app.patch("/v1/proactive", dependencies=[Depends(require_token)])
async def update_proactive(body: ProactiveUpdate) -> dict:
    ideas.update_settings(**body.model_dump(exclude_none=True))
    return proactive_state()


def find_idea(idea_id: str):
    if not re.fullmatch(r"[0-9a-f]{12}", idea_id) or not (idea := ideas.get(idea_id)):
        raise HTTPException(404, "Idée introuvable")
    return idea


@app.get("/v1/ideas", dependencies=[Depends(require_token)])
async def list_ideas(status: Literal["new", "seen", "opened", "dismissed"] | None = None,
                     goal_id: str | None = None) -> list[dict]:
    """Every idea except the dismissed ones, or those with `status`."""
    return [i.public() for i in ideas.list(status, goal_id)]


@app.post("/v1/ideas/seen", dependencies=[Depends(require_token)])
async def ideas_seen() -> dict:
    """The user saw the list: the badge goes away, the ideas stay."""
    return {"seen": ideas.mark_seen()}


@app.patch("/v1/ideas/{idea_id}", dependencies=[Depends(require_token)])
async def update_idea(idea_id: str, body: IdeaUpdate) -> dict:
    idea = find_idea(idea_id)
    changes: dict = {"status": body.status}
    if body.status == OPENED and body.conversation_id:
        changes["conversation_id"] = body.conversation_id
    if body.status == DISMISSED and idea.status != DISMISSED:
        # Remembered, so Marcel stops bringing up this kind of thing.
        memory.add(f"L'utilisateur n'est pas intéressé par : {idea.title} (objectif « {idea.goal_title} »)",
                   importance=2, source="idees", reason="idée refusée")
    return ideas.update(idea_id, **changes).public()


@app.delete("/v1/ideas/{idea_id}", dependencies=[Depends(require_token)])
async def delete_idea(idea_id: str) -> dict:
    idea = find_idea(idea_id)
    ideas.delete(idea_id)
    return idea.public()
