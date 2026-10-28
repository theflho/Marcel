"""Small rules: routine schedules, guard routes, protected code paths."""

import time
from zoneinfo import ZoneInfo

import pytest

from app.code_tools import CodeError, CodeWorkspace
from app.llm_guard import parse_routes
from app.routines import Routine, days_from_names, describe, is_due, valid_time

PARIS = ZoneInfo("Europe/Paris")


def test_days_and_times():
    assert days_from_names(["lundi", "jeudi"]) == "0,3"
    assert days_from_names(["semaine"]) == "0,1,2,3,4"
    assert days_from_names([]) == ""
    with pytest.raises(ValueError):
        days_from_names(["blurp"])
    assert valid_time("8h") == "08:00" and valid_time("18h30") == "18:30"
    assert describe("0", "08:00") == "Chaque lundi à 8 h"


def test_routine_runs_once_per_slot():
    now = time.time()
    routine = Routine(id="r", title="t", prompt="p", days="", at=time.strftime("%H:%M", time.localtime(now - 60)),
                      status="active", conversation_id="C", created_at=now - 86400 * 2, updated_at=now,
                      last_run_at=None)
    assert is_due(routine, now, None)
    routine.last_run_at = now - 30
    assert not is_due(routine, now, None)


def test_guard_routes():
    routes = parse_routes("claude-|https://api.example.com/v1/|k|1000;bad")
    assert routes == [{"prefix": "claude-", "url": "https://api.example.com/v1", "key": "k", "budget": 1000}]


@pytest.mark.parametrize("path", [".env", "backend/.env", ".github/workflows/ci.yml", "backend/deploy/auto-update.sh",
                                  "backend/app/code_tools.py", "backend/app/llm_guard.py", "../dehors.txt"])
def test_protected_paths(tmp_path, path):
    workspace = CodeWorkspace(tmp_path, "", "", mock_remote="unused")
    (tmp_path / "repo").mkdir()
    with pytest.raises(CodeError):
        workspace.path(path, writing=True)


def test_guard_blocks_stay_as_on_main():
    from pathlib import Path

    from app.code_tools import guard_problems

    main = (Path(__file__).parents[1] / "app" / "main.py").read_text()
    assert "# garde-fou : contenu extérieur" in main
    assert guard_problems("main.py", main, main) == []
    weakened = main.replace('return any(a.get("id") in ("mail", "files", "private")', 'return False and any(a.get("id") in ("mail", "files", "private")')
    assert guard_problems("main.py", main, weakened)
    assert guard_problems("main.py", main, main + "\n\ndef from_outside(mission):\n    return False\n")
    assert guard_problems("main.py", main, main + "\nBROWSER_GUARD = False\n")
    assert guard_problems("main.py", main, main.replace("LONG_MESSAGE_CHARS = 1500", "LONG_MESSAGE_CHARS = 2000")) == []


def test_guard_cant_be_overwritten_from_another_file():
    from app.code_tools import guard_problems

    assert guard_problems("x.py", "", "from . import main\nmain.from_outside = lambda m: False\n", {"from_outside"})
    assert guard_problems("x.py", "", "setattr(main, 'approves', lambda m: True)\n", {"approves"})
    assert guard_problems("x.py", "", "if main.from_outside(m) == True:\n    pass\n", {"from_outside"}) == []


def test_bot_profiles_are_planned_and_finished(tmp_path):
    import json

    from app.hermes_profiles import plan, prepare

    home = tmp_path / "hermes"
    (home / "profiles" / "marcel-old").mkdir(parents=True)
    (home / "profiles" / "perso").mkdir()  # the user's own profile: never touched
    bot = home / "profiles" / "marcel-planning"
    bot.mkdir()
    (home / ".env").write_text("API_SERVER_KEY=cle-principale\nAPI_SERVER_ENABLED=true\n")
    (home / "config.yaml").write_text('mcp_servers:\n  marcel:\n    url: "http://127.0.0.1:8000/mcp"\n'
                                      '    headers:\n      Authorization: "Bearer k"\n'
                                      'platform_toolsets:\n  api_server: [web, kanban]\n')
    (bot / "config.yaml").write_text("model:\n  default: m\n")
    (bot / ".env").write_text("KEY=1\nAPI_SERVER_ENABLED=true\nAPI_SERVER_PORT=8642")
    wanted = tmp_path / "profiles.json"
    wanted.write_text(json.dumps({"prefix": "marcel-", "profiles": [
        {"name": "marcel-planning", "bot": "planning", "soul": "Tu es Planning."},
        {"name": "marcel-veille", "bot": "veille", "soul": "Tu es Veille."},
        {"name": "Pas valide!", "bot": "x", "soul": ""}]}))

    assert plan(wanted, home) == ["create marcel-veille", "delete marcel-old"]
    assert prepare(wanted, home) == ["changed marcel-planning"]
    assert (bot / "SOUL.md").read_text() == "Tu es Planning."
    assert (bot / ".env").read_text() == "KEY=1\nAPI_SERVER_KEY=cle-principale\n"
    config = (bot / "config.yaml").read_text()
    assert "X-Marcel-Bot: planning" in config and "Bearer k" in config and "default: m" in config
    from ruamel.yaml import YAML
    assert YAML(typ="safe").load(config)["platform_toolsets"]["api_server"] == ["web", "kanban"]
    assert prepare(wanted, home) == []  # nothing changes twice
