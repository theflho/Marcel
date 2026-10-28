"""Marcel's changes to Hermes' configuration, applied by deploy/auto-update.sh on the VPS.

Marcel can't open a shell on the VPS. To change how Hermes runs (an MCP server, a skill folder,
an agent setting…), he edits backend/deploy/hermes-overrides.yaml in his repository; once merged,
the auto-update merges it into ~/.hermes/config.yaml (comments kept), restarts Hermes, checks it
still answers, and puts the previous file back if not.

The overlay only adds or changes keys, never removes one, and some stay the user's: the model
and its providers (the way to the LLM guard and its budgets), the gateway (its keys and
platforms), and any secret written in clear. One placeholder is replaced, ${MARCEL_MCP_TOKEN},
only for Marcel's own MCP server, so no other secret can be sent anywhere.

    python -m app.hermes_config apply <overlay.yaml> <config.yaml>   → "changed" or "unchanged"
    python -m app.hermes_config restore <config.yaml>                 → the copy from before
    python -m app.hermes_config ping                                  → exit 1 if Hermes doesn't answer
"""

from __future__ import annotations

import io
import os
import re
import shutil
import sys
from pathlib import Path

import httpx
from ruamel.yaml import YAML

# Top-level keys the user keeps for himself.
LOCKED = {"model", "provider", "providers", "custom_providers", "fallback_model", "fallback_providers",
          "auxiliary", "gateway", "delegation"}
SECRET_KEY = re.compile(r"key|token|secret|password|authorization", re.IGNORECASE)
PLACEHOLDER = "${MARCEL_MCP_TOKEN}"
BACKUP_SUFFIX = ".avant-marcel"
# Where Marcel's MCP server may be: the Docker network (Hermes in a container) or the port marcel-api
# publishes on the VPS itself (Hermes run by its own user, as on the VPS).
LOCAL_MCP = ("http://marcel-api:", "http://127.0.0.1:8000/")


class OverlayError(Exception):
    pass


def check(overlay, path: tuple[str, ...] = ()) -> None:
    """Refuses what the overlay may not do; raises OverlayError saying where."""
    if not isinstance(overlay, dict):
        raise OverlayError("le fichier doit être une table YAML (clé: valeur)")
    for key, value in overlay.items():
        here = path + (str(key),)
        where = ".".join(here)
        if not path and key in LOCKED:
            raise OverlayError(f"{where} reste réglé par l'utilisateur (modèle, fournisseurs, passerelle)")
        if here == ("mcp_servers", "marcel", "url") and not str(value).startswith(LOCAL_MCP):
            raise OverlayError(f"{where} : le serveur MCP marcel reste interne (http://marcel-api:… ou "
                               "http://127.0.0.1:8000/…)")
        if value is None:
            raise OverlayError(f"{where} : on ne retire pas une clé (valeur vide)")
        if isinstance(value, dict):
            check(value, here)
        elif isinstance(value, str) and (SECRET_KEY.search(str(key)) or "${" in value):
            if PLACEHOLDER not in value or here[:2] != ("mcp_servers", "marcel") or value.count("${") > 1:
                raise OverlayError(f"{where} : pas de secret dans ce fichier (seul {PLACEHOLDER}, pour le "
                                   "serveur MCP marcel)")


def merge(base, overlay) -> bool:
    """Deep-merges overlay into base (in place); True if something changed."""
    changed = False
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            changed |= merge(base[key], value)
        elif base.get(key) != value:
            base[key] = value
            changed = True
    return changed


def substitute(node, token: str):
    if isinstance(node, dict):
        return {k: substitute(v, token) for k, v in node.items()}
    if isinstance(node, list):
        return [substitute(v, token) for v in node]
    return node.replace(PLACEHOLDER, token) if isinstance(node, str) else node


def apply(overlay_path: Path, config_path: Path) -> str:
    yaml = YAML()
    yaml.preserve_quotes = True
    overlay = YAML(typ="safe").load(overlay_path.read_text()) or {}
    check(overlay)
    overlay = substitute(overlay, os.environ.get("MARCEL_MCP_TOKEN", ""))
    config = yaml.load(config_path.read_text()) if config_path.exists() else {}
    if not merge(config, overlay):
        return "unchanged"
    out = io.StringIO()
    yaml.dump(config, out)
    if config_path.exists():
        shutil.copy2(config_path, config_path.with_name(config_path.name + BACKUP_SUFFIX))
    config_path.write_text(out.getvalue())
    return "changed"


def restore(config_path: Path) -> None:
    backup = config_path.with_name(config_path.name + BACKUP_SUFFIX)
    if not backup.exists():
        raise OverlayError("aucune copie précédente")
    shutil.copy2(backup, config_path)


def ping() -> bool:
    url = os.environ.get("HERMES_URL", "http://hermes:8642").rstrip("/")
    try:
        reply = httpx.get(f"{url}/v1/models", headers={"Authorization": f"Bearer {os.environ.get('HERMES_API_KEY', '')}"},
                          timeout=10)
        return reply.status_code == 200
    except httpx.HTTPError:
        return False


if __name__ == "__main__":
    command, *args = sys.argv[1:] or ["?"]
    try:
        if command == "apply" and len(args) == 2:
            print(apply(Path(args[0]), Path(args[1])))
        elif command == "restore" and len(args) == 1:
            restore(Path(args[0]))
            print("restored")
        elif command == "ping":
            sys.exit(0 if ping() else 1)
        else:
            sys.exit(__doc__)
    except OverlayError as error:
        sys.exit(f"Refusé : {error}")
