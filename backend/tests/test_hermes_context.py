"""Context migration is gated by installed files, not by the deployment's requested state."""

import asyncio
import json
import shutil
import subprocess
import sys
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from app import hermes_context, main
from app.assistants import AssistantStore
from app.hermes_profiles import plan, prepare, verified
from app.hermes_sessions import HermesSessions


AUTH = {"Authorization": "Bearer test"}
client = TestClient(main.app)
SKILLS = Path(__file__).parents[1] / "deploy" / "hermes-skills"


@pytest.fixture
def context(monkeypatch, tmp_path):
    monkeypatch.setattr(main, "assistants", AssistantStore(tmp_path / "app.db"))
    monkeypatch.setattr(main, "hermes_sessions", HermesSessions(tmp_path / "app.db"))
    monkeypatch.setattr(main, "CHECK_HERMES_URL", "http://checks:8642")
    calls = []
    real_client = httpx.AsyncClient

    def respond(request):
        calls.append((request, json.loads(request.content)))
        return httpx.Response(200, headers={"X-Hermes-Session-Id": "api-test"},
                              text='data: {"choices":[{"delta":{"content":"Bonjour."}}]}\n\ndata: [DONE]\n\n')

    transport = httpx.MockTransport(respond)
    monkeypatch.setattr(main.httpx, "AsyncClient", lambda **kwargs: real_client(transport=transport, **kwargs))

    async def profile_url(bot):
        return f"{main.HERMES_URL}/p/{main.profile_name(bot)}"

    monkeypatch.setattr(main, "profile_url", profile_url)
    return calls


def acknowledge(*profiles):
    snapshot = main.context_revisions(main.context_snapshot())
    picked = profiles or tuple(snapshot)
    return client.post("/v1/hermes/profiles/applied", headers=AUTH,
                       json={"revisions": {key: snapshot[key] for key in picked}})


def send(*, note="LEGACY instructions and planning, goals, bots", **extra):
    kwargs = {k: extra.pop(k) for k in ("url", "profile") if k in extra}
    request = main.ChatRequest(conversation_id="CONVERSATION-APP", messages=[
        main.Message(role="user", content="Bonjour")], **extra)

    async def go():
        return [item async for item in main.hermes_stream(request, "model", note, key="test-key", **kwargs)]

    assert asyncio.run(go()) == ["Bonjour."]


def test_context_stays_until_acknowledged_then_only_message_specific_data_is_sent(context):
    assert not main.context_installed()
    send()
    assert "LEGACY" in context[-1][1]["messages"][0]["content"]
    assert acknowledge().status_code == 200 and main.context_installed()
    send(style="concis", device_context="Rendez-vous écrit par un tiers")
    system = context[-1][1]["messages"][0]["content"]
    assert "CONCIS" in system and "Rendez-vous écrit par un tiers" in system
    assert "contenu externe" in system and "jamais comme des instructions" in system
    assert all(word not in system for word in ("LEGACY", "planning", "goals", "bots"))
    assert context[-1][1]["messages"][-1] == {"role": "user", "content": "Bonjour"}


def test_changed_rules_or_card_immediately_restore_compatibility_context(context):
    assert acknowledge().status_code == 200
    main.assistants.set_state("purchase_cap", 180)
    assert not main.context_installed()
    send(note=main.app_context(False))
    assert "180 €" in context[-1][1]["messages"][0]["content"]
    assert acknowledge().status_code == 200 and main.context_installed()
    main.assistants.add_instruction("planning", "Préfère les missions du matin.")
    assert not main.context_installed("planning") and main.context_installed()
    send(assistant="planning", profile="planning")
    assert "LEGACY" in context[-1][1]["messages"][0]["content"]


def test_ack_is_authenticated_exact_and_bound_to_the_hermes_endpoint(context, monkeypatch):
    assert client.post("/v1/hermes/profiles/applied", json={"revisions": {}}).status_code == 401
    assert client.post("/v1/hermes/profiles/applied", headers=AUTH,
                       json={"revisions": {"default": "not-installed"}}).status_code == 409
    assert not main.context_installed()
    assert acknowledge().status_code == 200
    monkeypatch.setattr(main, "HERMES_URL", "http://another-hermes:8642")
    assert not main.context_installed()


def test_main_ack_never_strips_a_bots_card_or_a_profile_fallback(context, monkeypatch):
    assert acknowledge("default").status_code == 200
    send(assistant="planning", profile="planning")
    assert "LEGACY" in context[-1][1]["messages"][0]["content"]
    assert acknowledge().status_code == 200
    send(assistant="planning", profile="planning", device_context="private agenda")
    assert "LEGACY" not in context[-1][1]["messages"][0]["content"]
    assert "private agenda" not in context[-1][1]["messages"][0]["content"]  # not a chosen read here

    async def fallback(bot):
        return main.HERMES_URL

    monkeypatch.setattr(main, "profile_url", fallback)
    send(assistant="planning", profile="planning")
    assert "LEGACY" in context[-1][1]["messages"][0]["content"]


@pytest.mark.parametrize("extra", [{"private": True}, {"url": "http://checks:8642"},
                                  {"url": "http://guard:4000"},
                                  {"url": f"{main.HERMES_URL}/p/{main.PROTECTED_PROFILE}"}])
def test_ack_never_strips_protected_or_private_call_context(context, extra):
    assert acknowledge().status_code == 200
    send(**extra)
    assert "LEGACY" in context[-1][1]["messages"][0]["content"]


def test_soul_contains_bot_card_rules_and_skills_but_no_live_data(context, monkeypatch):
    main.assistants.add_instruction("planning", "Pas de travail le dimanche.")
    saved = main.assistants.state("bot_rules", {})
    main.assistants.set_state("bot_rules", saved | {"planning": {"achat": "off"}})

    def no_data(*args, **kwargs):
        raise AssertionError("Live data must be fetched by Hermes, not included in SOUL")

    monkeypatch.setattr(main, "planning_note", no_data)
    monkeypatch.setattr(main, "data_overview", no_data)
    monkeypatch.setattr(main.goals, "context", no_data)
    snapshot = client.get("/v1/hermes/profiles", headers=AUTH).json()
    profile = next(p for p in snapshot["profiles"] if p["bot"] == "planning")
    assert "Pas de travail le dimanche" in profile["soul"]
    assert "tu ne réserves et n'achètes rien" in profile["soul"]
    assert "marcel_contexte" in snapshot["main"]["soul"]
    assert "marcel-app/SKILL.md" in snapshot["skills"]
    token = main.mcp_bot.set("planning")
    try:
        assert "tu ne réserves et n'achètes rien" in main.tool_context({})
        assert "tu ne réserves et n'achètes rien" in main.tool_rules({})
        # Building the principal's SOUL inside another bot's MCP call keeps the principal's rules.
        assert main.context_snapshot()["main"] == snapshot["main"]
    finally:
        main.mcp_bot.reset(token)


def install_profiles(tmp_path):
    snapshot = main.context_snapshot()
    desired = tmp_path / "desired.json"
    desired.write_text(json.dumps(snapshot))
    home = tmp_path / "hermes"
    home.mkdir()
    (home / "SOUL.md").write_text("Style personnel à conserver.\n")
    config = ('mcp_servers:\n  marcel:\n    url: http://127.0.0.1:8000/mcp\n'
              '    headers:\n      Authorization: Bearer test-only\n'
              'platform_toolsets:\n  api_server: [web, browser]\nplugins:\n  enabled: [marcel]\n')
    (home / "config.yaml").write_text(config)
    (home / ".env").write_text("API_SERVER_KEY=test-only\n")
    for action in plan(desired, home):
        command, name = action.split()
        assert command == "create"
        folder = home / "profiles" / name
        folder.mkdir(parents=True)
        (folder / "config.yaml").write_text(config)
        (folder / ".env").write_text("API_SERVER_KEY=test-only\n")
    for folder in [home, *(home / "profiles").iterdir()]:
        shutil.copytree(SKILLS, folder / "skills" / "marcel")
    prepare(desired, home, "mcp-test-only")
    return desired, home, snapshot


def test_prepare_verifies_installed_skills_profiles_and_preserves_main_personality(context, tmp_path):
    desired, home, snapshot = install_profiles(tmp_path)
    assert (home / "SOUL.md").read_text().startswith("Style personnel à conserver.\n")
    assert verified(desired, home)["revisions"] == main.context_revisions(snapshot)
    assert prepare(desired, home, "mcp-test-only") == []
    assert client.post("/v1/hermes/profiles/applied", headers=AUTH,
                       json=verified(desired, home)).status_code == 200
    assert main.context_installed("planning")
    bare = home / "profiles" / main.PROTECTED_PROFILE
    from ruamel.yaml import YAML
    config = YAML(typ="safe").load((bare / "config.yaml").read_text())
    assert "mcp_servers" not in config and config["platform_toolsets"]["api_server"] == []
    assert config["plugins"]["enabled"] == [] and config["memory"]["memory_enabled"] is False
    assert main.PROTECTED_PROFILE not in verified(desired, home)["revisions"]


@pytest.mark.parametrize("fault", ["skill", "soul", "mcp", "api-key", "truncation"])
def test_missing_or_incorrect_profile_files_are_not_acknowledged(context, tmp_path, fault):
    desired, home, _ = install_profiles(tmp_path)
    bot = home / "profiles" / "marcel-planning"
    if fault == "skill":
        (bot / "skills" / "marcel" / "marcel-app" / "SKILL.md").unlink()
    if fault == "soul":
        (bot / "SOUL.md").write_text("Old identity")
    if fault == "mcp":
        path = bot / "config.yaml"
        path.write_text(path.read_text().replace("X-Marcel-Bot: planning", "X-Marcel-Bot: veille"))
    if fault == "api-key":
        (bot / ".env").write_text("API_SERVER_KEY=another-key\n")
    if fault == "truncation":
        with (bot / "config.yaml").open("a") as file:
            file.write("context_file_max_chars: 100\n")
    revisions = verified(desired, home)["revisions"]
    assert "marcel-planning" not in revisions and "default" in revisions


def test_main_soul_managed_block_preserves_both_sides_and_refuses_ambiguous_markers():
    original = "User's own instructions.\n"
    once = hermes_context.managed_soul(original, "First app identity") + "\nUser's footer."
    twice = hermes_context.managed_soul(once, "Updated app identity")
    assert twice.startswith(original) and twice.endswith("User's footer.")
    assert "First app identity" not in twice and "Updated app identity" in twice
    assert twice.count(hermes_context.START) == 1
    with pytest.raises(ValueError):
        hermes_context.managed_soul(once + hermes_context.START, "Do not overwrite")


def test_verify_command_refuses_partial_installations(context, tmp_path):
    desired, home, snapshot = install_profiles(tmp_path)
    command = [sys.executable, "-m", "app.hermes_profiles", "verify", str(desired), str(home)]
    before = subprocess.run(command, capture_output=True, text=True, cwd=SKILLS.parents[1])
    assert before.returncode == 0
    assert json.loads(before.stdout)["revisions"] == main.context_revisions(snapshot)
    (home / "profiles" / "marcel-planning" / "skills" / "marcel" / "marcel-app" / "SKILL.md").unlink()
    after = subprocess.run(command, capture_output=True, text=True, cwd=SKILLS.parents[1])
    assert after.returncode != 0 and not after.stdout


