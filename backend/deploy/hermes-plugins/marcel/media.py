"""Transfer local Hermes outputs to Marcel's authenticated attachment store before delivery."""

import mimetypes
from pathlib import Path

MAX_BYTES = 20 * 1024 * 1024
MAX_FILES = 10


async def post_delivery(client, url: str, key: str, bot: str, text: str, paths=()) -> dict:
    paths = list(paths)
    if len(paths) > MAX_FILES:
        raise ValueError("Au plus 10 fichiers par message")
    # Check every input before uploading, so a missing/oversized file never becomes a false success.
    files = []
    for raw in paths:
        path = Path(raw)
        if not path.is_file():
            raise ValueError("Fichier à envoyer introuvable")
        if path.stat().st_size > MAX_BYTES:
            raise ValueError("Fichier trop volumineux (20 Mo maximum)")
        files.append(path)
    headers = {"Authorization": f"Bearer {key}"}
    attachments = []
    for path in files:
        with path.open("rb") as source:
            response = await client.post(f"{url.rstrip('/')}/v1/hermes/files", headers=headers,
                files={"file": (path.name, source, mimetypes.guess_type(path.name)[0] or "application/octet-stream")})
        response.raise_for_status()
        attachments.append(response.json()["id"])
    response = await client.post(f"{url.rstrip('/')}/v1/hermes/deliver", headers=headers,
                                json={"bot": bot, "text": text, "attachments": attachments})
    response.raise_for_status()
    return response.json()
