"""Real multipart-to-inbox-to-download path, with no real Hermes dependency or credential."""

import asyncio
import importlib.util
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from app import main
from app.assistants import AssistantStore
from app.missions import MissionStore


APP = {"Authorization": "Bearer test"}
HERMES = {"Authorization": "Bearer mcp-test"}
client = TestClient(main.app)
spec = importlib.util.spec_from_file_location("hermes_media", Path(__file__).parents[1] /
                                            "deploy/hermes-plugins/marcel/media.py")
media = importlib.util.module_from_spec(spec)
spec.loader.exec_module(media)


@pytest.fixture
def files(monkeypatch, tmp_path):
    monkeypatch.setattr(main, "FILES_DIR", tmp_path / "files")
    monkeypatch.setattr(main, "assistants", AssistantStore(tmp_path / "app.db"))
    monkeypatch.setattr(main, "missions", MissionStore(tmp_path / "app.db"))
    return tmp_path


def test_real_plugin_transfer_reaches_inbox_and_authenticated_download(files):
    pdf = files / "Résultat.pdf"
    image = files / "image.png"
    pdf.write_bytes(b"%PDF-test-output")
    image.write_bytes(b"\x89PNG-test-output")
    async def go():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=main.app)) as api:
            return await media.post_delivery(api, "http://testserver", "mcp-test", "planning", "Voici le résultat", [pdf, image])
    delivered = asyncio.run(go())
    pending = client.get("/v1/bot-messages", headers=APP).json()
    assert len(pending) == 1 and pending[0]["id"] == delivered["id"]
    entry = pending[0]
    assert entry["assistant"] == "planning" and entry["text"] == "Voici le résultat"
    assert [f["filename"] for f in entry["attachments"]] == [pdf.name, image.name]
    assert [f["mime_type"] for f in entry["attachments"]] == ["application/pdf", "image/png"]
    for meta, source in zip(entry["attachments"], (pdf, image)):
        route = f"/v1/files/{meta['id']}/content"
        assert client.get(route).status_code == 401
        assert client.get(route, headers=HERMES).status_code == 401
        response = client.get(route, headers=APP)
        assert response.content == source.read_bytes() and meta["size"] == len(response.content)
    assert client.post(f"/v1/bot-messages/{entry['id']}/delivered", headers=APP).status_code == 200
    assert client.get("/v1/bot-messages", headers=APP).json() == []


def test_file_only_delivery_and_wrong_keys_or_unknown_files(files):
    assert client.post("/v1/hermes/files", headers=APP, files={"file": ("x.txt", b"x")}).status_code == 401
    upload = client.post("/v1/hermes/files", headers=HERMES, files={"file": ("x.txt", b"x")}).json()
    assert client.post("/v1/hermes/deliver", headers=HERMES,
                       json={"attachments": [upload["id"]]}).json()["id"] > 0
    assert len(client.get("/v1/bot-messages", headers=APP).json()[0]["attachments"]) == 1
    assert client.post("/v1/hermes/deliver", headers=HERMES,
                       json={"attachments": ["a" * 32]}).status_code == 404
    assert client.get("/v1/files/../../etc/passwd/content", headers=APP).status_code != 200
    assert client.get("/v1/files/bad/content", headers=APP).status_code == 400


def test_size_limit_and_emergency_apply_to_native_upload_and_delivery(files, monkeypatch):
    monkeypatch.setattr(main, "MAX_UPLOAD_BYTES", 16)
    assert client.post("/v1/hermes/files", headers=HERMES,
                       files={"file": ("too-large.txt", b"x" * 17)}).status_code == 413
    assert not [p for p in main.FILES_DIR.iterdir() if p.is_file()]
    asyncio.run(main.missions.emergency_stop())
    assert client.post("/v1/hermes/files", headers=HERMES, files={"file": ("x.txt", b"x")}).status_code == 423
    assert client.post("/v1/hermes/deliver", headers=HERMES, json={"text": "test"}).status_code == 423


def test_missing_or_large_file_never_reports_delivery_success(files):
    large = files / "large.bin"
    with large.open("wb") as out:
        out.truncate(media.MAX_BYTES + 1)
    calls = []
    def respond(request):
        calls.append(request)
        return httpx.Response(200)
    async def go():
        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as api:
            for path in (files / "missing.txt", large):
                with pytest.raises(ValueError):
                    await media.post_delivery(api, "http://test", "key", "planning", "texte", [path])
    asyncio.run(go())
    assert not calls


def test_failed_upload_does_not_send_a_delivery_receipt(files):
    source = files / "x.txt"
    source.write_text("test")
    calls = []
    def respond(request):
        calls.append(str(request.url))
        return httpx.Response(503)
    async def go():
        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as api:
            with pytest.raises(httpx.HTTPStatusError):
                await media.post_delivery(api, "http://test", "key", "planning", "texte", [source])
    asyncio.run(go())
    assert calls == ["http://test/v1/hermes/files"]
