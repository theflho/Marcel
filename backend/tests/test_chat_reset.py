"""An explicit user reset clears both sides, without disabling safeguards or other Hermes channels."""

import asyncio
import uuid

import httpx
import pytest
from fastapi.testclient import TestClient

from app import main
from app.assistants import AssistantStore
from app.chat_reset import clear_api_history
from app.hermes_sessions import HermesSessions
from app.missions import Mission, MissionStore
from app.routines import RoutineStore
from app.semantic import SemanticIndex

AUTH = {"Authorization": "Bearer test"}
client = TestClient(main.app)


@pytest.fixture
def reset(monkeypatch, tmp_path):
    db = tmp_path / "reset.db"
    monkeypatch.setattr(main, "assistants", AssistantStore(db))
    monkeypatch.setattr(main, "missions", MissionStore(db))
    monkeypatch.setattr(main, "hermes_sessions", HermesSessions(db))
    monkeypatch.setattr(main, "routines", RoutineStore(db, main.USER_TZ))
    monkeypatch.setattr(main, "vectors", SemanticIndex(db))
    monkeypatch.setattr(main, "FILES_DIR", tmp_path / "files")
    monkeypatch.setattr(main, "MOCK", False)
    urls = []
    async def native(targets, key):
        urls.extend(targets)
        return 13
    monkeypatch.setattr(main, "clear_api_history", native)
    return db, urls


def test_reset_is_user_only_and_does_not_run_without_the_explicit_scope(reset):
    assert client.post("/v1/chat/reset", json={"scope": "bots_and_history"}).status_code == 401
    assert client.post("/v1/chat/reset", headers={"Authorization": "Bearer mcp-test"},
                       json={"scope": "bots_and_history"}).status_code == 401
    assert client.post("/v1/chat/reset", headers=AUTH, json={}).status_code == 422
    assert len(main.assistants.all()) == 5


def test_reset_removes_bots_history_and_stale_deliveries_but_keeps_user_rules(reset):
    db, urls = reset
    custom = main.assistants.create("Test", "Mission utile", "tree")
    main.assistants.set_state("rules", {"achat": "ask"})
    installed = {"endpoint": main.HERMES_URL, "revisions": main.context_revisions(main.context_snapshot())}
    main.assistants.set_state("hermes_context_installed", installed)
    main.assistants.add_instruction("planning", "Ancienne consigne")
    main.assistants.set_state("hermes_conversations", {"": "OLD"})
    mission = Mission(uuid.uuid4().hex, "OLD", status="done", text="Ancienne conversation")
    main.missions.save(mission)
    main.assistants.add_inbox("", "OLD", "", mission.id)
    routine = main.routines.add("Ancienne tâche", "Ancienne consigne", assistant=custom.id)
    main.FILES_DIR.mkdir()
    (main.FILES_DIR / "old-file").write_text("Ancienne pièce jointe")
    first = [{"role": "user", "content": "Ancien message"}]
    followup = first + [{"role": "assistant", "content": "OK"}, {"role": "user", "content": "Suite"}]
    main.hermes_sessions.put("http://hermes", "", "OLD", "api-old", first)
    assert main.hermes_sessions.get("http://hermes", "", "OLD", followup) == "api-old"
    response = client.post("/v1/chat/reset", headers=AUTH, json={"scope": "bots_and_history"})
    assert response.status_code == 200 and response.json()["native_sessions_deleted"] == 13
    generation = response.json()["reset_id"]
    assert client.get("/health", headers=AUTH).json()["reset_id"] == generation
    assert client.get("/v1/assistants", headers=AUTH).json() == []
    assert client.get("/v1/missions", headers=AUTH).json() == []
    assert client.get("/v1/bot-messages", headers=AUTH).json() == []
    assert main.assistants.state("rules") == {"achat": "ask"}
    assert main.assistants.state("hermes_context_installed") == installed
    assert not main.missions.emergency
    assert not main.assistants.find("planning") and not main.assistants.find(custom.id)
    assert main.assistants.value("planning", "hour") == 19  # internal robot configuration remains valid
    assert main.hermes_sessions.get("http://hermes", "", "OLD", followup) is None
    assert main.routines.get(routine.id).status == "paused" and main.routines.get(routine.id).conversation_id == ""
    assert not list(main.FILES_DIR.iterdir())
    assert len(urls) == 8  # default + five built-ins + custom + protected
    assert f"/p/{main.PROTECTED_PROFILE}" in urls[-1]
    # A restart must not bring the built-ins back. New bots may still be created on demand.
    reloaded = AssistantStore(db)
    assert reloaded.all() == []
    snapshot = main.context_snapshot()
    assert all(p.get("bare") for p in snapshot["profiles"])
    assert reloaded.create("Cuisine", "Aider en cuisine", "cooking").name == "Cuisine"


def test_native_failure_does_not_acknowledge_a_completed_reset(reset, monkeypatch):
    async def fail(*args):
        raise httpx.ConnectError("private transport detail")
    monkeypatch.setattr(main, "clear_api_history", fail)
    response = client.post("/v1/chat/reset", headers=AUTH, json={"scope": "bots_and_history"})
    assert response.status_code == 502 and "private" not in response.text
    assert not main.assistants.state("chat_reset_id")


def test_native_cleanup_is_source_scoped_and_deletes_through_hermes(monkeypatch):
    calls = []
    remaining = {"api-one", "api-two"}
    real_client = httpx.AsyncClient
    def respond(request):
        calls.append(request)
        if request.method == "GET":
            assert request.url.params["source"] == "api_server"
            if "/p/marcel-missing/" in str(request.url):
                return httpx.Response(404)
            return httpx.Response(200, json={"data": [{"id": i, "source": "api_server"} for i in sorted(remaining)]})
        remaining.remove(request.url.path.rsplit("/", 1)[1])
        return httpx.Response(200, json={"deleted": True})
    monkeypatch.setattr(httpx, "AsyncClient", lambda **kw:real_client(transport=httpx.MockTransport(respond), **kw))
    count = asyncio.run(clear_api_history(["http://hermes", "http://hermes/p/marcel-missing"], "test-key"))
    assert count == 2 and not remaining
    assert all(r.headers["Authorization"] == "Bearer test-key" for r in calls)


def test_native_cleanup_refuses_an_unexpected_channel(monkeypatch):
    methods = []
    real_client = httpx.AsyncClient
    def respond(request):
        methods.append(request.method)
        return httpx.Response(200, json={"data": [{"id": "local-one", "source": "local"}]})
    monkeypatch.setattr(httpx, "AsyncClient", lambda **kw:real_client(transport=httpx.MockTransport(respond), **kw))
    with pytest.raises(ValueError):
        asyncio.run(clear_api_history(["http://hermes"], "test-key"))
    assert methods == ["GET"]
