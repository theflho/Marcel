"""Native Hermes events, exact-run approvals, and honest tools/skills discovery."""

import asyncio
import importlib.util
import json
import uuid
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app import main
from app.hermes_approvals import HermesApprovals
from app.hermes_capabilities import capabilities
from app.missions import Mission, MissionStore


AUTH = {"Authorization": "Bearer test"}
client = TestClient(main.app)


@pytest.fixture
def native(monkeypatch, tmp_path):
    replies, calls = [], []
    real_client = httpx.AsyncClient

    def respond(request):
        calls.append(request)
        return replies.pop(0) if replies else httpx.Response(200, json={"resolved": 1})

    transport = httpx.MockTransport(respond)
    monkeypatch.setattr(main.httpx, "AsyncClient", lambda **kw: real_client(transport=transport, **kw))
    monkeypatch.setattr(main, "hermes_approvals", HermesApprovals())
    monkeypatch.setattr(main, "missions", MissionStore(tmp_path / "native.db"))
    return replies, calls


def new_mission(conversation):
    mission = Mission(uuid.uuid4().hex, conversation)
    main.missions.save(mission)
    return mission


def frame(kind, data):
    return (f"event: {kind}\n" if kind else "") + "data: " + json.dumps(data) + "\n\n"


async def stream(**kwargs):
    return [item async for item in main.hermes_events("http://hermes/p/marcel-planning", AUTH,
            {}, kwargs.pop("browser", True), kwargs.pop("vault", False), None, "CONVERSATION", **kwargs)]


def test_native_tools_and_legacy_text_are_visible_and_completed(native):
    replies, _ = native
    event = {"toolCallId": "native-1", "tool": "skills_list", "label": "Lister les skills"}
    replies.append(httpx.Response(200, text=frame("hermes.tool.progress", event | {"status": "running"})
        + frame("", {"choices": [{"delta": {"content": "Je regarde."}}]})
        + frame("hermes.tool.progress", event | {"status": "completed"}) + "data: [DONE]\n\n"))
    items = asyncio.run(stream())
    assert items[0]["name"] == "skills_list" and items[0]["status"] == "running"
    assert items[1] == "Je regarde."
    assert items[2]["id"] == "native-1" and items[2]["status"] == "done"


@pytest.mark.parametrize("tool,browser,vault,blocked", [
    ("browser_navigate", True, False, False), ("browser_navigate", False, False, True),
    ("browser_vault", True, False, True), ("browser_vault", True, True, False)])
def test_native_browser_keeps_protected_and_vault_gates_only(native, tool, browser, vault, blocked):
    replies, _ = native
    replies.append(httpx.Response(200, text=frame("hermes.tool.progress",
        {"toolCallId": "browser-1", "tool": tool, "status": "running"}) + "data: [DONE]\n\n"))
    if blocked:
        with pytest.raises(main.MissionError):
            asyncio.run(stream(browser=browser, vault=vault))
    else:
        assert asyncio.run(stream(browser=browser, vault=vault))[0]["name"] == tool


def test_sse_multiline_comments_and_event_reset():
    async def go():
        async def lines():
            for line in [": ping", "event: approval.request", 'data: {"run_id":', 'data: "run-1"}', "",
                         'data: {"choices": []}']:
                yield line
        return [item async for item in main.hermes_sse(lines())]
    assert asyncio.run(go()) == [("approval.request", '{"run_id":\n"run-1"}'), ("", '{"choices": []}')]


def test_native_approval_is_scoped_live_one_time_and_cleaned(native):
    replies, calls = native
    event = {"run_id": "chatcmpl-run1", "request_id": "approval1", "execution_generation": 4,
             "command": "echo test", "choices": ["once", "always", "deny"]}
    replies.append(httpx.Response(200, text=frame("approval.request", event) + "data: [DONE]\n\n"))

    async def go():
        # A real mission belongs to the same conversation but the UI never gets native ids/credentials.
        mission = new_mission("CONVERSATION")
        other = new_mission("OTHER")
        source = main.hermes_events("http://hermes/p/marcel-planning", {"Authorization": "Bearer native-secret"},
                                    {}, True, False, None, "CONVERSATION")
        action = await anext(source)
        mission.record(action)
        main.missions.save(mission)
        other.record(action)
        main.missions.save(other)
        assert "native-secret" not in json.dumps(mission.public()) and "chatcmpl-run1" not in json.dumps(action)
        with pytest.raises(HTTPException) as error:
            await main.approve_hermes(other.id, action["id"], main.HermesApprovalChoice(choice="once"))
        assert error.value.status_code == 409
        assert client.post(f"/v1/missions/{mission.id}/hermes-approval/{action['id']}",
                           headers=AUTH, json={"choice": "always"}).status_code == 422
        assert client.post(f"/v1/missions/{mission.id}/hermes-approval/{action['id']}",
                           json={"choice": "once"}).status_code == 401
        await main.missions.emergency_stop()
        with pytest.raises(HTTPException) as error:
            await main.approve_hermes(mission.id, action["id"], main.HermesApprovalChoice(choice="once"))
        assert error.value.status_code == 423
        main.missions.emergency_resume()
        result = await main.approve_hermes(mission.id, action["id"], main.HermesApprovalChoice(choice="once"))
        assert result["status"] == "done"
        assert calls[-1].url == "http://hermes/p/marcel-planning/v1/runs/chatcmpl-run1/approval"
        assert calls[-1].headers["Authorization"] == "Bearer native-secret"
        assert json.loads(calls[-1].content) == {"choice": "once", "request_id": "approval1", "execution_generation": 4}
        with pytest.raises(HTTPException):
            await main.approve_hermes(mission.id, action["id"], main.HermesApprovalChoice(choice="once"))
        await source.aclose()
        assert not main.hermes_approvals.pending
    asyncio.run(go())


@pytest.mark.parametrize("choice", ["deny", "once"])
def test_native_approval_failure_retry_and_expiration(native, choice):
    replies, _ = native
    replies += [httpx.Response(200, text=frame("approval.request", {"run_id": "chatcmpl-2", "request_id": "r"})
                                         + "data: [DONE]\n\n"), httpx.Response(409, text="secret upstream error")]

    async def go():
        mission = new_mission("CONVERSATION")
        source = main.hermes_events("http://hermes", AUTH, {}, True, False, None, "CONVERSATION")
        action = await anext(source)
        mission.record(action)
        main.missions.save(mission)
        with pytest.raises(HTTPException) as error:
            await main.approve_hermes(mission.id, action["id"], main.HermesApprovalChoice(choice=choice))
        assert error.value.status_code == 502 and "secret" not in error.value.detail
        assert not main.hermes_approvals.pending[action["id"]].busy
        result = await main.approve_hermes(mission.id, action["id"], main.HermesApprovalChoice(choice=choice))
        assert result["status"] == ("done" if choice == "once" else "cancelled")
        await source.aclose()
    asyncio.run(go())


def test_approval_cleanup_on_disconnect(native):
    replies, _ = native
    replies.append(httpx.Response(200, text=frame("approval.request", {"run_id": "run1"})))
    async def go():
        source = main.hermes_events("http://hermes", AUTH, {}, True, False, None)
        await anext(source)
        assert main.hermes_approvals.pending
        await source.aclose()
        assert not main.hermes_approvals.pending
    asyncio.run(go())


def test_capabilities_are_allowlisted_and_errors_are_honest(native):
    replies, _ = native
    replies += [httpx.Response(200, json={"data": [{"name": "web", "enabled": True, "configured": True,
                "tools": ["web_search"], "configuration": "secret-token"}]}), httpx.Response(500, text="secret-token")]
    result = asyncio.run(capabilities("http://hermes", "secret-key"))
    assert result["toolsets"][0]["tools"] == ["web_search"]
    assert result["skills"] == [] and "HTTP 500" in result["issues"][0]
    assert "secret" not in json.dumps(result)


def test_capabilities_api_auth_emergency_and_profile_scope(native, monkeypatch):
    replies, calls = native
    assert client.get("/v1/hermes/capabilities").status_code == 401
    assert client.get("/v1/hermes/capabilities?assistant=missing", headers=AUTH).status_code == 404
    asyncio.run(main.missions.emergency_stop())
    assert client.get("/v1/hermes/capabilities", headers=AUTH).status_code == 423
    assert not calls
    main.missions.emergency_resume()
    async def profile(bot):
        return "http://hermes/p/marcel-planning"
    monkeypatch.setattr(main, "profile_url", profile)
    replies += [httpx.Response(200, json={"data": []}),
                httpx.Response(200, json={"data": [{"name": "marcel-app", "description": "App", "category": "app"}]})]
    result = client.get("/v1/hermes/capabilities?assistant=planning", headers=AUTH).json()
    assert result["ready"] and result["skills"][0]["name"] == "marcel-app"
    assert all(str(call.url).startswith("http://hermes/p/marcel-planning/v1/") for call in calls)


def test_skills_signature_compat_preserves_disabled_filter_and_modern_api():
    spec = importlib.util.spec_from_file_location("skills_compat", Path(__file__).parents[1] /
                                                "deploy/hermes-plugins/marcel/compat.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    def old(*, skip_disabled=False):
        return ["enabled"] if skip_disabled else ["enabled", "disabled"]
    catalog = SimpleNamespace(find_all_skills=old)
    assert module.skills_api_compat(catalog)
    assert catalog.find_all_skills(include_editorial=True) == ["enabled", "disabled"]
    assert catalog.find_all_skills(skip_disabled=True, include_editorial=True) == ["enabled"]
    assert not module.skills_api_compat(catalog)
    def modern(*, skip_disabled=False, include_editorial=False):
        return include_editorial
    catalog.find_all_skills = modern
    assert not module.skills_api_compat(catalog)
    assert catalog.find_all_skills is modern


def test_old_browser_rule_no_longer_limits_native_web_or_bot_profile(native, monkeypatch, tmp_path):
    from app.assistants import AssistantStore

    monkeypatch.setattr(main, "assistants", AssistantStore(tmp_path / "cards.db"))
    main.assistants.set_state("rules", {"navigateur": "off", "achat": "ask"})
    main.assistants.set_state("bot_rules", {"planning": {"navigateur": "off", "compte": "off"}})
    result = client.get("/v1/rules", headers=AUTH).json()
    assert "navigateur" not in result["rules"] and "navigateur" not in result["labels"]
    assert main.rule("achat") == "ask" and main.rule("compte", "planning") == "off"
    soul = main.profile_soul(main.assistants.find("planning"))
    assert "Agir sur un site (navigateur)" not in soul
    assert "hors outils web natifs" in soul
