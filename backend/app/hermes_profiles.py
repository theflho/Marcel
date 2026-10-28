"""The bots' Hermes profiles, kept in step with Marcel by deploy/auto-update.sh on the VPS.

Each bot is a Hermes profile (`marcel-<bot>` in <hermes home>/profiles/), served by the main
gateway under /p/<profile>/ (gateway.multiplex_profiles). Marcel says which ones there should be
(GET /v1/hermes/profiles); the script creates the missing ones with Hermes' own command (a copy of
the main profile: model, tools, Marcel's MCP server and skills, never its messaging tokens), deletes
the ones whose bot is gone, then runs this module to finish each one:

- SOUL.md: the bot's identity, durable card and current rules; the main profile keeps the user's
  own text around a managed app block;
- config.yaml: Marcel's MCP server as in the main profile (address, key), saying which bot is
  calling (X-Marcel-Bot), so its tools follow that bot's rules and memory; and the main profile's
  API toolsets (platform_toolsets.api_server), so a bot has the same Hermes tools as Marcel;
- .env: without API_SERVER_ENABLED/HOST/PORT (the main gateway's port: a second profile binding it
  is skipped), with the main profile's API_SERVER_KEY (requests under /p/<profile>/ check the
  profile's own key, and Marcel only has the main one).

A "bare" profile (marcel-protege, for e-mails) is the opposite: no MCP server, no tool, no plugin,
no memory and no background review, and nothing to deliver with, so what strangers wrote can't make
it act, send or remember anything.

Only profiles named with the prefix are ever touched, so the user's own profiles are never touched.

    python -m app.hermes_profiles plan <desired.json> <hermes home>     → "create <name>" / "delete <name>"
    python -m app.hermes_profiles prepare <desired.json> <hermes home>  → "changed <name>" per profile changed
    python -m app.hermes_profiles verify <desired.json> <hermes home>   → installed revisions, or exit 1
"""

from __future__ import annotations

import io
import hashlib
import json
import os
import re
import sys
from pathlib import Path

from ruamel.yaml import YAML

from .hermes_context import MAIN_PROFILE, managed_soul, revision

NAME = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
PORT_ENV = re.compile(r"^\s*(export\s+)?API_SERVER_(ENABLED|HOST|PORT)=")
KEY_ENV = re.compile(r"^\s*(export\s+)?API_SERVER_KEY=(.*)$")
SETTING_ENV = re.compile(r"^\s*(export\s+)?([A-Z_]+)=")
# Lists of the main profile's config.yaml every bot's profile gets too: the same Hermes tools in the
# app, and the « marcel » platform plugin.
COPIED = (("platform_toolsets", "api_server"), ("plugins", "enabled"))
MAIN_CHANNEL = "marcel"
DELIVERY = ("MARCEL_DELIVER_KEY", "MARCEL_HOME_CHANNEL")
BARE_MEMORY = {"memory_enabled": False, "user_profile_enabled": False, "nudge_interval": 0}


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


def prepare(desired_path: Path, home: Path, deliver_key: str = "") -> list[str]:
    _, profiles = desired(desired_path)
    main = main_settings(home)
    key = main_key(home)
    data = json.loads(desired_path.read_text())
    done = finish_env(home, None, delivery(deliver_key, MAIN_CHANNEL), bot=False)
    if main_soul := (data.get("main") or {}).get("soul"):
        path = home / "SOUL.md"
        previous = path.read_text() if path.exists() else ""
        done |= finish_soul(home, managed_soul(previous, main_soul))
    changed = ["changed main"] if done else []
    for profile in profiles:
        folder = home / "profiles" / profile["name"]
        if not folder.is_dir():
            continue
        if profile.get("bare"):
            done = finish_soul(folder, profile["soul"]) | finish_bare(folder) | finish_env(folder, key, {}, drop=DELIVERY)
        else:
            done = (finish_soul(folder, profile["soul"]) | finish_config(folder, profile["bot"], main)
                    | finish_env(folder, key, delivery(deliver_key, profile["bot"])))
        if done:
            changed.append(f"changed {profile['name']}")
    return changed


def verified(desired_path: Path, home: Path) -> dict:
    """Prove what was installed, not just what the server asked us to install.

    Only auto-update, after restarting and probing Hermes, sends these revisions back to Marcel.
    The protected profile never participates in the ordinary conversation contract.
    """
    data = json.loads(desired_path.read_text())
    _, profiles = desired(desired_path)
    skills = data.get("skills") or {}
    candidates = [(MAIN_PROFILE, home, data.get("main") or {})]
    candidates += [(p["name"], home / "profiles" / p["name"], p) for p in profiles if not p.get("bare")]
    applied = {}
    server, copied = main_settings(home)
    for name, folder, profile in candidates:
        soul = profile.get("soul")
        path = folder / "SOUL.md"
        if not soul or not path.is_file() or not skills or not server:
            continue
        expected = managed_soul("", soul).strip() if name == MAIN_PROFILE else soul
        actual = path.read_text()
        if not (expected in actual if name == MAIN_PROFILE else expected == actual):
            continue
        if any(not (file := folder / "skills" / "marcel" / rel).is_file()
               or hashlib.sha256(file.read_bytes()).hexdigest() != fingerprint
               for rel, fingerprint in skills.items() if valid_skill_path(rel)):
            continue
        if not all(valid_skill_path(rel) for rel in skills):
            continue
        config_path = folder / "config.yaml"
        config = (YAML(typ="safe").load(config_path.read_text()) if config_path.is_file() else None) or {}
        # Hermes' default context-file cap is at least 20,000 characters (larger windows may
        # raise it). An explicit smaller cap wins: never acknowledge a truncated identity/rule set.
        cap = config.get("context_file_max_chars")
        cap = int(cap) if isinstance(cap, (int, float)) and cap > 0 else 20_000
        if len(actual.strip()) > cap:
            continue
        mcp = (config.get("mcp_servers") or {}).get("marcel") or {}
        wanted = (dict(server) | {"headers": dict(server.get("headers") or {}) | {"X-Marcel-Bot": profile["bot"]}}
                  if name != MAIN_PROFILE else server)
        if mcp != wanted:
            continue
        if any((config.get(section) or {}).get(key) != value for (section, key), value in copied.items()):
            continue
        if main_key(folder) != main_key(home) or not main_key(folder):
            continue
        fingerprint = revision(soul, skills)
        if fingerprint == profile.get("revision"):
            applied[name] = fingerprint
    return {"revisions": applied}


def valid_skill_path(path: str) -> bool:
    parts = Path(path).parts
    return bool(parts) and not Path(path).is_absolute() and ".." not in parts


def delivery(deliver_key: str, bot: str) -> dict[str, str]:
    """The « marcel » platform's settings (deploy/hermes-plugins/marcel): Marcel's key, and the bot
    this profile's cron jobs and messages go to. None without the key: nothing to deliver with."""
    return dict(zip(DELIVERY, (deliver_key, bot))) if deliver_key else {}


def finish_bare(folder: Path) -> bool:
    """The protected profile: nothing to act with, nothing to remember with."""
    path = folder / "config.yaml"
    if not path.exists():
        return False
    yaml = YAML()
    yaml.preserve_quotes = True
    config = yaml.load(path.read_text()) or {}
    before = json.dumps(config, sort_keys=True, default=str)
    config.pop("mcp_servers", None)
    config.setdefault("platform_toolsets", {})["api_server"] = []
    config.setdefault("plugins", {})["enabled"] = []
    config.setdefault("memory", {}).update(BARE_MEMORY)
    config.setdefault("skills", {})["creation_nudge_interval"] = 0
    if json.dumps(config, sort_keys=True, default=str) == before:
        return False
    out = io.StringIO()
    yaml.dump(config, out)
    path.write_text(out.getvalue())
    return True


def finish_soul(folder: Path, soul: str) -> bool:
    path = folder / "SOUL.md"
    if path.exists() and path.read_text() == soul:
        return False
    path.write_text(soul)
    return True


def main_settings(home: Path) -> tuple[dict | None, dict[tuple[str, str], list]]:
    """What every bot's profile copies from the main one: Marcel's MCP server, and the COPIED lists."""
    path = home / "config.yaml"
    config = (YAML(typ="safe").load(path.read_text()) if path.exists() else None) or {}
    server = (config.get("mcp_servers") or {}).get("marcel")
    copied = {(section, key): value for section, key in COPIED
              if isinstance(value := (config.get(section) or {}).get(key), list)}
    return (server if isinstance(server, dict) else None), copied


def finish_config(folder: Path, bot: str, main: tuple[dict | None, dict[tuple[str, str], list]]) -> bool:
    path = folder / "config.yaml"
    server, copied = main
    if not path.exists() or server is None:
        return False  # the main profile has no Marcel server yet: nothing to copy
    wanted = dict(server) | {"headers": dict(server.get("headers") or {}) | {"X-Marcel-Bot": bot}}
    yaml = YAML()
    yaml.preserve_quotes = True
    config = yaml.load(path.read_text()) or {}
    servers = config.setdefault("mcp_servers", {})
    same = dict(servers.get("marcel") or {}) == wanted and all(
        list((config.get(section) or {}).get(key) or []) == value for (section, key), value in copied.items())
    if same:
        return False
    servers["marcel"] = wanted
    for (section, key), value in copied.items():
        config.setdefault(section, {})[key] = list(value)
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


def finish_env(folder: Path, key: str | None, settings: dict[str, str], bot: bool = True,
               drop: tuple[str, ...] = ()) -> bool:
    """A bot's .env: without the port lines, with the main API_SERVER_KEY. The main profile's own
    (bot False) keeps its port and key. Both: the « marcel » platform's settings."""
    path = folder / ".env"
    if not path.exists():
        return False
    lines = path.read_text().splitlines(keepends=True)
    owned = SETTING_ENV.match
    kept = [line for line in lines
            if not (bot and (PORT_ENV.match(line) or (key is not None and KEY_ENV.match(line))))
            and not ((m := owned(line)) and (m.group(2) in settings or m.group(2) in drop))]
    wanted = ([f"API_SERVER_KEY={key}\n"] if bot and key is not None else []) + [f"{k}={v}\n" for k, v in settings.items()]
    if kept and wanted and not kept[-1].endswith("\n"):
        kept[-1] += "\n"
    kept += wanted
    if kept == lines:
        return False
    path.write_text("".join(kept))
    return True


if __name__ == "__main__":
    command, *args = sys.argv[1:] or ["?"]
    if command in ("plan", "prepare", "verify") and len(args) == 2:
        if command == "plan":
            print("\n".join(plan(Path(args[0]), Path(args[1]))))
        elif command == "verify":
            path, home = Path(args[0]), Path(args[1])
            data = json.loads(path.read_text())
            wanted = {MAIN_PROFILE: data.get("main", {}).get("revision")} | {
                p["name"]: p.get("revision") for p in desired(path)[1] if not p.get("bare")}
            found = verified(path, home)
            if found["revisions"] != wanted:
                sys.exit("Profils ou skills incomplets : contexte de compatibilité conservé.")
            print(json.dumps(found))
        else:  # the key the « marcel » platform delivers with: Marcel's MCP one, from its .env
            print("\n".join(prepare(Path(args[0]), Path(args[1]), os.environ.get("MARCEL_MCP_TOKEN", ""))))
    else:
        print(__doc__)
        sys.exit(2)
