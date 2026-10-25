"""Code requests: for a big change, Marcel hands it to a coding agent and a PR comes back.

Marcel changes his code himself with his own tools (app/code_tools.py). For a bigger job he can
write a request instead; only the user's tap ("Envoyer à Claude Code" or "à Codex") turns it into
a GitHub issue on the app's repository, labelled for the chosen agent:
- "marcel": .github/workflows/marcel-code.yml, Claude Code (branch claude/issue-<n>-…);
- "marcel-codex": .github/workflows/marcel-codex.yml, OpenAI Codex (branch codex/issue-<n>-…).
Either opens a pull request the user reads and merges on GitHub.

The GitHub key (MARCEL_GITHUB_TOKEN, fine-grained, this repository only) lives in the server's
.env, never in the app; the agents' own keys are secrets of the repository on GitHub.
"""

from __future__ import annotations

import re
import secrets
import sqlite3
import time
from pathlib import Path

import httpx

# Agent → (issue label that starts its workflow, name shown in the app).
AGENTS = {"claude": ("marcel", "Claude Code"), "codex": ("marcel-codex", "Codex (OpenAI)")}
DEFAULT_AGENT = "claude"
COLUMNS = ("id", "title", "body", "conversation_id", "mission_id", "issue_number", "issue_url", "created_at", "agent")
MAX_TITLE_CHARS, MAX_BODY_CHARS = 120, 4000

ISSUE_RULES = """---
Demande envoyée depuis l'app Marcel par son propriétaire, après relecture.

Règles pour l'agent de code :
- Une seule pull request, sur une branche à part ; rien n'est fusionné ni déployé : le propriétaire relit.
- Ne touche jamais au serveur (VPS), aux secrets ni aux fichiers .env ; aucune clé dans l'application.
- Respecte le style du dépôt (README, commentaires, noms) et lance les vérifications disponibles.
- Si la demande est floue ou risquée, n'écris pas de code : explique en commentaire ce qu'il faut préciser."""


class GitHubError(Exception):
    """A refusal or failure from GitHub, said to the user."""


class CodeRequestStore:
    def __init__(self, db_path: Path, repo: str = "", token: str = "", mock: bool = False):
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self.repo, self.token, self.mock = repo, token, mock
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        self._db.execute(
            """CREATE TABLE IF NOT EXISTS code_requests (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                conversation_id TEXT NOT NULL DEFAULT '',
                mission_id TEXT NOT NULL DEFAULT '',
                issue_number INTEGER,
                issue_url TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL
            )"""
        )
        if "agent" not in {row[1] for row in self._db.execute("PRAGMA table_info(code_requests)")}:
            self._db.execute(f"ALTER TABLE code_requests ADD COLUMN agent TEXT NOT NULL DEFAULT '{DEFAULT_AGENT}'")
        self._db.commit()

    @property
    def configured(self) -> bool:
        return self.mock or bool(self.repo and self.token)

    def list(self) -> list[dict]:
        rows = self._db.execute(f"SELECT {', '.join(COLUMNS)} FROM code_requests ORDER BY created_at DESC LIMIT 50")
        return [dict(zip(COLUMNS, row)) for row in rows]

    def sent_for(self, mission_id: str) -> dict | None:
        row = self._db.execute(f"SELECT {', '.join(COLUMNS)} FROM code_requests WHERE mission_id = ?",
                               (mission_id,)).fetchone()
        return dict(zip(COLUMNS, row)) if row else None

    async def send(self, title: str, body: str, conversation_id: str, mission_id: str,
                   agent: str = DEFAULT_AGENT) -> dict:
        """Opens the issue that starts the agent's workflow, and keeps a trace of it here."""
        agent = agent if agent in AGENTS else DEFAULT_AGENT
        title = " ".join(title.split())[:MAX_TITLE_CHARS]
        body = body.strip()[:MAX_BODY_CHARS]
        request = {"id": secrets.token_hex(6), "title": title, "body": body, "conversation_id": conversation_id,
                   "mission_id": mission_id, "created_at": time.time(), "agent": agent}
        if self.mock:
            number = 100 + len(self.list())
            request |= {"issue_number": number, "issue_url": f"https://github.com/{self.repo or 'exemple/marcel'}/issues/{number}"}
        else:
            issue = await self._github("POST", f"/repos/{self.repo}/issues",
                                       json={"title": title, "body": f"{body}\n\n{ISSUE_RULES}", "labels": [AGENTS[agent][0]]})
            request |= {"issue_number": issue["number"], "issue_url": issue["html_url"]}
        self._db.execute(f"INSERT INTO code_requests ({', '.join(COLUMNS)}) VALUES ({', '.join('?' * len(COLUMNS))})",
                         tuple(request[c] for c in COLUMNS))
        self._db.commit()
        return request

    async def statuses(self) -> list[dict]:
        """Each request with where it stands on GitHub: "en cours", "pr", "fusionnee", "fermee"."""
        requests = self.list()
        if self.mock or not requests:
            return [r | {"state": "en cours", "pr_url": "", "pr_title": ""} for r in requests]
        try:
            issues = await self._github("GET", f"/repos/{self.repo}/issues", params={"state": "all", "per_page": 100})
            pulls = await self._github("GET", f"/repos/{self.repo}/pulls", params={"state": "all", "per_page": 50})
        except GitHubError:
            return [r | {"state": "inconnu", "pr_url": "", "pr_title": ""} for r in requests]
        issue_state = {i["number"]: i["state"] for i in issues}
        out = []
        for r in requests:
            number = r["issue_number"]
            # The agents' branches are named claude/issue-<number>-… or codex/issue-<number>-…
            pr = next((p for p in pulls if re.match(rf"(claude|codex)/issue-{number}-", p["head"]["ref"])
                       or f"#{number}" in (p.get("body") or "")), None)
            if pr and pr.get("merged_at"):
                state = "fusionnee"
            elif pr and pr["state"] == "open":
                state = "pr"
            elif issue_state.get(number) == "closed" or (pr and pr["state"] == "closed"):
                state = "fermee"
            else:
                state = "en cours"
            out.append(r | {"state": state, "pr_url": pr["html_url"] if pr else "", "pr_title": pr["title"] if pr else ""})
        return out

    async def _github(self, method: str, path: str, **kwargs):
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28"}
        try:
            async with httpx.AsyncClient(base_url="https://api.github.com", timeout=15) as client:
                resp = await client.request(method, path, headers=headers, **kwargs)
        except httpx.HTTPError:
            raise GitHubError("GitHub injoignable depuis le serveur.") from None
        if resp.status_code in (401, 403):
            raise GitHubError("GitHub refuse la clé du serveur (MARCEL_GITHUB_TOKEN) : droits ou expiration.")
        if resp.status_code == 404:
            raise GitHubError(f"Dépôt {self.repo} introuvable avec cette clé.")
        if resp.status_code >= 400:
            raise GitHubError(f"GitHub a refusé la demande ({resp.status_code}).")
        return resp.json()
