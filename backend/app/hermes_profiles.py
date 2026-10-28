"""The bots' Hermes profiles, kept in step with Marcel by deploy/auto-update.sh on the VPS.

Each bot is a Hermes profile (`marcel-<bot>` in <hermes home>/profiles/), served by the main
gateway under /p/<profile>/ (gateway.multiplex_profiles). Marcel says which ones there should be
(GET /v1/hermes/profiles); the script creates the missing ones with Hermes' own command (a copy of
the main profile: model, tools, Marcel's MCP server and skills, never its messaging tokens), deletes
the ones whose bot is gone, then runs this module to finish each one:

- SOUL.md: who the bot is;
- config.yaml: Marcel's MCP server as in the main profile (address, key), saying which bot is
  calling (X-Marcel-Bot), so its tools follow that bot's rules and memory;
- .env: without API_SERVER_ENABLED/HOST/PORT (the main gateway's port: a second profile binding it
  is skipped), with the main profile's API_SERVER_KEY (requests under /p/<profile>/ check the
  profile's own key, and Marcel only has the main one).

Only profiles named with the prefix are ever touched, so the user's own profiles are never touched.

    python -m app.hermes_profiles plan <desired.json> <hermes home>     → "create <name>" / "delete <name>"
    python -m app.hermes_profiles prepare <desired.json> <hermes home>  → "changed <name>" per profile changed
"""

from __future__ import annotations

import io
import json
import re
import sys
from pathlib import Path

from ruamel.yaml import YAML

NAME = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
PORT_ENV = re.compile(r"^\s*(export\s+)?API_SERVER_(ENABLED|HOST|PORT)=")
KEY_ENV = re.compile(r"^\s*(export\s+)?API_SERVER_KEY=(.*)$")


def desired(path: Path) -> tuple[str, list[dict]]:
    data = json.loads(path.read_text())
    prefix = data["prefix"]
    profiles = [p for p in data["profiles"] if NAME.match(p["name"]) and p["name"].startswith(prefix)]
    return prefix, profiles


def plan(desired_path: Path, home: Path) -> list[str]:
    prefix, profiles = desired(desired_path)
    root = home / "profiles"
    present = {d.name for d in root.iterdir() if d.is_dir()} if root.is_dir() else set()
    wanted = {p["name"] for p in profiles}
    return ([f"create {name}" for name in sorted(wanted - present)]
            + [f"delete {name}" for name in sorted(present - wanted) if name.startswith(prefix)])


def prepare(desired_path: Path, home: Path) -> list[str]:
    _, profiles = desired(desired_path)
    main = main_server(home)
    key = main_key(home)
    changed = []
    for profile in profiles:
        folder = home / "profiles" / profile["name"]
        if folder.is_dir() and (finish_soul(folder, profile["soul"]) | finish_config(folder, profile["bot"], main)
                                | finish_env(folder, key)):
            changed.append(f"changed {profile['name']}")
    return changed


def finish_soul(folder: Path, soul: str) -> bool:
    path = folder / "SOUL.md"
    if path.exists() and path.read_text() == soul:
        return False
    path.write_text(soul)
    return True


def main_server(home: Path) -> dict | None:
    """Marcel's MCP server in the main profile, which every bot's profile copies."""
    path = home / "config.yaml"
    config = YAML(typ="safe").load(path.read_text()) if path.exists() else None
    server = ((config or {}).get("mcp_servers") or {}).get("marcel")
    return server if isinstance(server, dict) else None


def finish_config(folder: Path, bot: str, main: dict | None) -> bool:
    path = folder / "config.yaml"
    if not path.exists() or main is None:
        return False  # the main profile has no Marcel server yet: nothing to copy
    wanted = dict(main) | {"headers": dict(main.get("headers") or {}) | {"X-Marcel-Bot": bot}}
    yaml = YAML()
    yaml.preserve_quotes = True
    config = yaml.load(path.read_text()) or {}
    servers = config.setdefault("mcp_servers", {})
    if dict(servers.get("marcel") or {}) == wanted:
        return False
    servers["marcel"] = wanted
    out = io.StringIO()
    yaml.dump(config, out)
    path.write_text(out.getvalue())
    return True


def main_key(home: Path) -> str | None:
    """The main profile's API_SERVER_KEY line value, the one Marcel calls Hermes with."""
    path = home / ".env"
    found = [m.group(2) for line in (path.read_text().splitlines() if path.exists() else [])
             if (m := KEY_ENV.match(line))]
    return found[-1] if found else None


def finish_env(folder: Path, key: str | None) -> bool:
    path = folder / ".env"
    if not path.exists():
        return False
    lines = path.read_text().splitlines(keepends=True)
    kept = [line for line in lines if not PORT_ENV.match(line) and not (key is not None and KEY_ENV.match(line))]
    if key is not None:
        if kept and not kept[-1].endswith("\n"):
            kept[-1] += "\n"
        kept.append(f"API_SERVER_KEY={key}\n")
    if kept == lines:
        return False
    path.write_text("".join(kept))
    return True


if __name__ == "__main__":
    command, *args = sys.argv[1:] or ["?"]
    if command in ("plan", "prepare") and len(args) == 2:
        run = plan if command == "plan" else prepare
        print("\n".join(run(Path(args[0]), Path(args[1]))))
    else:
        print(__doc__)
        sys.exit(2)
