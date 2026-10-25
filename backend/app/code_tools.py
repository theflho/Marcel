"""Marcel's own hands on his code: read, search, change, check, open a pull request and merge it.

Marcel works in his own copy of the app's repository (MARCEL_DATA_DIR/code/repo), never in the
server's: a change reaches the VPS only once merged on GitHub, when deploy/auto-update.sh (cron
on the VPS) pulls it, rebuilds, checks /health and goes back to the previous version if it fails.

The GitHub key (MARCEL_GITHUB_TOKEN) stays in the server: it's passed to git for each call, never
written in the copy nor shown to the model. A few files stay out of reach, because they are the
safety net itself: the secrets (.env…), GitHub's workflows, the auto-update with its way back, and
this file.

Inside the files Marcel may change, the safeguards themselves (the emergency stop, the protected
mode for e-mails and files, the browser cut-off…) sit between two comments:
    # garde-fou : <nom>
    …
    # fin garde-fou : <nom>
Every such block of main must stay exactly as it is, and what it defines can't be defined again
elsewhere (a later `def from_outside` would quietly win). Checked when writing and before a push.
"""

from __future__ import annotations

import asyncio
import base64
import os
import re
import time
from pathlib import Path

import httpx

# Files Marcel can't change (relative to the repository), and why.
PROTECTED = (
    (re.compile(r"(^|/)\.env|\.env$|(^|/)(guard|rma)\.env|\.key$|\.pem$"), "un fichier de secrets"),
    (re.compile(r"^\.github/"), "les workflows GitHub"),
    (re.compile(r"^backend/deploy/auto-update\.sh$"), "la mise à jour automatique et son retour arrière"),
    (re.compile(r"^backend/app/code_tools\.py$"), "ses propres garde-fous de code"),
    (re.compile(r"^backend/app/(llm_guard|mcp|server_log|hermes_config)\.py$"),
     "un garde-fou (budgets, accès des outils, secrets masqués, config de Hermes)"),
    (re.compile(r"^backend/tests/test_server\.py$"), "les tests des garde-fous"),
)
GUARD_START = re.compile(r"^[ \t]*# garde-fou : (.+?)[ \t]*$", re.MULTILINE)
BRANCH_PREFIX = "marcel/"
MAX_READ_LINES, MAX_FILE_BYTES, MAX_OUTPUT_CHARS = 400, 400_000, 8_000


class CodeError(Exception):
    """Said to the model as the tool's answer."""


def guard_blocks(text: str) -> dict[str, str]:
    """name → the block's exact text, markers included."""
    blocks = {}
    for match in GUARD_START.finditer(text):
        name = match.group(1)
        end = re.compile(rf"^[ \t]*# fin garde-fou : {re.escape(name)}[ \t]*$", re.MULTILINE).search(text, match.end())
        blocks[name] = text[match.start():end.end()] if end else text[match.start():]
    return blocks


DEFINITION = re.compile(r"^(?:async def|def|class)\s+(\w+)|^([A-Z_][A-Z0-9_]*)\s*=(?!=)", re.MULTILINE)


def defined_names(block: str) -> set[str]:
    """Functions, classes and constants a guard block defines at the top level."""
    return {a or b for a, b in DEFINITION.findall(block)}


def guard_problems(relative: str, before: str, after: str, guarded: set[str] = frozenset()) -> list[str]:
    """What a change does to the safeguards of one file ([] if nothing). guarded: what the guard
    blocks of the whole repository define, which no file may overwrite (`main.from_outside = …`)."""
    problems = [f"{name} (un garde-fou) est remplacé depuis {relative}" for name in sorted(guarded)
                if re.search(rf"\.{name}\s*=(?!=)|setattr\([^)]*['\"]{name}['\"]", after)]
    kept = guard_blocks(after)
    names: set[str] = set()
    for name, block in guard_blocks(before).items():
        if kept.get(name) != block:
            problems.append(f"le garde-fou « {name} » de {relative} a changé ou disparu")
        names |= defined_names(block)
    outside = after
    for block in kept.values():
        outside = outside.replace(block, "")
    for name in sorted(names):
        if re.search(rf"^(?:async def|def|class)\s+{name}\b|^{name}\s*=(?!=)|\.{name}\s*=(?!=)", outside, re.MULTILINE):
            problems.append(f"{name} (garde-fou de {relative}) est redéfini ailleurs")
    return problems


class CodeWorkspace:
    def __init__(self, root: Path, repo: str, token: str, mock_remote: str = ""):
        self.root = root
        self.dir = root / "repo"
        self.repo, self.token = repo, token
        # Tests: a local bare repository instead of GitHub.
        self.mock_remote = mock_remote
        self.lock = asyncio.Lock()

    @property
    def configured(self) -> bool:
        return bool(self.mock_remote or (self.repo and self.token))

    # MARK: git

    async def git(self, *args: str, check: bool = True) -> str:
        auth = []
        if self.token and not self.mock_remote:
            basic = base64.b64encode(f"x-access-token:{self.token}".encode()).decode()
            auth = ["-c", f"http.https://github.com/.extraheader=AUTHORIZATION: basic {basic}"]
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(self.root), "GIT_TERMINAL_PROMPT": "0",
               "GIT_CONFIG_NOSYSTEM": "1"}
        process = await asyncio.create_subprocess_exec(
            "git", "-c", "user.name=Marcel", "-c", "user.email=marcel@localhost", *auth, *args,
            cwd=self.dir if self.dir.exists() else self.root, env=env,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        out, _ = await process.communicate()
        text = out.decode(errors="replace")
        if self.token:
            text = text.replace(self.token, "***")
        if check and process.returncode:
            raise CodeError(f"git {args[0]} a échoué : {text.strip()[-600:]}")
        return text

    @property
    def remote(self) -> str:
        return self.mock_remote or f"https://github.com/{self.repo}.git"

    async def ensure(self) -> None:
        if not self.configured:
            raise CodeError("Outils de code non branchés : MARCEL_GITHUB_REPO et MARCEL_GITHUB_TOKEN sont à régler "
                            "dans le .env du serveur.")
        self.root.mkdir(parents=True, exist_ok=True)
        if not (self.dir / ".git").exists():
            await self.git("clone", "--quiet", self.remote, str(self.dir))

    async def branch(self) -> str:
        return (await self.git("rev-parse", "--abbrev-ref", "HEAD")).strip()

    # MARK: Paths

    def path(self, relative: str, writing: bool = False) -> Path:
        relative = relative.strip().lstrip("/")
        target = (self.dir / relative).resolve()
        if not str(target).startswith(str(self.dir.resolve()) + os.sep) or "/.git/" in f"/{relative}/":
            raise CodeError(f"Chemin hors du dépôt : {relative}")
        if writing:
            for pattern, why in PROTECTED:
                if pattern.search(relative):
                    raise CodeError(f"{relative} est protégé ({why}) : seul l'utilisateur le modifie.")
        return target

    async def main_version(self, relative: str) -> str:
        """The file as it is on main ("" for a new file)."""
        if not (await self.git("ls-tree", "--name-only", "origin/main", "--", relative)).strip():
            return ""
        return await self.git("show", f"origin/main:{relative}")

    async def guarded_names(self) -> set[str]:
        """What the guard blocks on main define, in every file that has some."""
        files = (await self.git("grep", "-l", "# garde-fou : ", "origin/main", "--", "*.py", check=False)).split()
        names: set[str] = set()
        for found in files:
            text = await self.git("show", found)  # "origin/main:path"
            for block in guard_blocks(text).values():
                names |= defined_names(block)
        return names

    async def refuse_guard_changes(self, relative: str, after: str) -> None:
        if problems := guard_problems(relative, await self.main_version(relative), after,
                                      await self.guarded_names() if relative.endswith(".py") else set()):
            raise CodeError("Refusé, les garde-fous restent tels quels (seul l'utilisateur les change) : "
                            + " ; ".join(problems) + ".")

    # MARK: Tools

    async def start(self, subject: str) -> str:
        """A fresh branch from the latest main, for one change."""
        async with self.lock:
            await self.ensure()
            await self.git("fetch", "--quiet", "origin")
            await self.git("checkout", "--quiet", "-B", "main", "origin/main")
            await self.git("reset", "--quiet", "--hard", "origin/main")
            await self.git("clean", "-fdq")
            slug = re.sub(r"[^a-z0-9]+", "-", subject.lower()).strip("-")[:40] or "changement"
            name = f"{BRANCH_PREFIX}{slug}-{time.strftime('%m%d-%H%M')}"
            await self.git("checkout", "--quiet", "-b", name)
            head = (await self.git("log", "-1", "--format=%h %s")).strip()
        return f"Branche {name} créée depuis main ({head}). Lis, modifie, vérifie, puis marcel_code_proposer."

    async def resume(self, number: int, pulls: list[dict]) -> str:
        """Back on the branch of an open pull request, to change it again."""
        pull = next((p for p in pulls if p["number"] == number), None)
        if not pull or not pull["head"]["ref"].startswith(BRANCH_PREFIX):
            raise CodeError(f"Pull request #{number} introuvable parmi celles de Marcel.")
        async with self.lock:
            await self.ensure()
            ref = pull["head"]["ref"]
            await self.git("fetch", "--quiet", "origin", f"{ref}:refs/remotes/origin/{ref}")
            await self.git("checkout", "--quiet", "-B", ref, f"origin/{ref}")
        return f"De retour sur {ref} (#{number})."

    async def files(self, folder: str = "") -> str:
        await self.ensure()
        listed = (await self.git("ls-files", "--", folder.strip().lstrip("/") or ".")).splitlines()
        if not listed:
            return "Aucun fichier."
        return "\n".join(listed[:300]) + (f"\n… et {len(listed) - 300} autres" if len(listed) > 300 else "")

    async def read(self, relative: str, start: int = 1, end: int | None = None) -> str:
        await self.ensure()
        path = self.path(relative)
        if not path.is_file():
            raise CodeError(f"Fichier introuvable : {relative}")
        if path.stat().st_size > MAX_FILE_BYTES:
            raise CodeError("Fichier trop gros pour être lu en entier : lis une plage de lignes.")
        lines = path.read_text(errors="replace").splitlines()
        start = max(1, start)
        end = min(len(lines), end or start + MAX_READ_LINES - 1, start + MAX_READ_LINES - 1)
        body = "\n".join(f"{n:>5}\t{lines[n - 1]}" for n in range(start, end + 1))
        more = f"\n… lignes {end + 1} à {len(lines)} : relis avec debut={end + 1}" if end < len(lines) else ""
        return f"{relative} ({len(lines)} lignes)\n{body}{more}"

    async def search(self, pattern: str, folder: str = "") -> str:
        await self.ensure()
        out = await self.git("grep", "-n", "-I", "-E", "--", pattern, *([folder.strip().lstrip("/")] if folder else []),
                             check=False)
        lines = out.splitlines()
        if not lines:
            return "Rien trouvé."
        return "\n".join(line[:240] for line in lines[:120]) + (f"\n… {len(lines) - 120} de plus" if len(lines) > 120 else "")

    async def write(self, relative: str, content: str) -> str:
        async with self.lock:
            await self.ensure()
            await self.on_marcel_branch()
            path = self.path(relative, writing=True)
            content = content if content.endswith("\n") else content + "\n"
            await self.refuse_guard_changes(relative, content)
            path.parent.mkdir(parents=True, exist_ok=True)
            existed = path.exists()
            path.write_text(content)
        return f"{relative} {'remplacé' if existed else 'créé'} ({content.count(chr(10))} lignes)."

    async def replace(self, relative: str, old: str, new: str) -> str:
        async with self.lock:
            await self.ensure()
            await self.on_marcel_branch()
            path = self.path(relative, writing=True)
            if not path.is_file():
                raise CodeError(f"Fichier introuvable : {relative}")
            text = path.read_text()
            count = text.count(old)
            if count == 0:
                raise CodeError("Texte à remplacer introuvable : relis le fichier et recopie-le exactement.")
            if count > 1:
                raise CodeError(f"Texte trouvé {count} fois : ajoute des lignes autour pour qu'il soit unique.")
            changed = text.replace(old, new, 1)
            await self.refuse_guard_changes(relative, changed)
            path.write_text(changed)
        return f"{relative} modifié."

    async def check(self) -> str:
        """What can be checked here: Python compiles, shell scripts parse, JSON/YAML read."""
        await self.ensure()
        changed = await self.changed_files()
        results = []
        for relative in changed:
            path = self.dir / relative
            if not path.exists():
                continue
            if relative.endswith(".py"):
                # compile() rather than py_compile, which would leave __pycache__ to be committed.
                command = ["python3", "-c", "import sys; compile(open(sys.argv[1]).read(), sys.argv[1], 'exec')",
                           str(path)]
            elif relative.endswith(".sh"):
                command = ["bash", "-n", str(path)]
            elif relative.endswith(".json"):
                command = ["python3", "-c", "import json,sys; json.load(open(sys.argv[1]))", str(path)]
            else:
                continue
            process = await asyncio.create_subprocess_exec(*command, stdout=asyncio.subprocess.PIPE,
                                                           stderr=asyncio.subprocess.STDOUT)
            out, _ = await process.communicate()
            results.append(f"{'OK' if process.returncode == 0 else 'ERREUR'} {relative}"
                           + (f"\n{out.decode(errors='replace').strip()[-800:]}" if process.returncode else ""))
        if not changed:
            return "Aucun fichier modifié."
        swift = [f for f in changed if f.endswith(".swift")]
        note = (f"\n{len(swift)} fichier(s) Swift : pas de Xcode sur le serveur, non compilé(s) ici ; "
                "la CI de GitHub les compile après marcel_code_proposer (voir marcel_code_ci).") if swift else ""
        return "\n".join(results or ["Rien à vérifier automatiquement dans ces fichiers."]) + note

    async def changed_files(self) -> list[str]:
        base = "origin/main"
        committed = (await self.git("diff", "--name-only", f"{base}...HEAD", check=False)).splitlines()
        working = (await self.git("status", "--porcelain")).splitlines()
        names = committed + [line[3:].split(" -> ")[-1] for line in working]
        return sorted(set(filter(None, names)))

    async def diff(self) -> str:
        await self.ensure()
        await self.git("add", "-A")
        text = await self.git("diff", "--cached", "--stat")
        text += "\n" + await self.git("diff", "--cached")
        if not text.strip():
            return "Aucune modification en cours."
        return text[:MAX_OUTPUT_CHARS] + ("\n… (coupé)" if len(text) > MAX_OUTPUT_CHARS else "")

    async def commit_and_push(self, message: str) -> str:
        """Commits what changed and pushes the branch; returns the branch name."""
        async with self.lock:
            await self.ensure()
            branch = await self.on_marcel_branch()
            for relative in await self.changed_files():
                path = self.dir / relative
                await self.refuse_guard_changes(relative, path.read_text(errors="replace") if path.is_file() else "")
            if "ERREUR " in (checked := await self.check()):
                raise CodeError(f"Vérification ratée, rien n'est parti :\n{checked}")
            await self.git("add", "-A")
            staged = (await self.git("diff", "--cached", "--name-only")).splitlines()
            for relative in staged:
                self.path(relative, writing=True)  # a protected file changed by other means stops here
            if staged:
                await self.git("commit", "--quiet", "-m", message)
            elif not (await self.git("log", "origin/main..HEAD", "--oneline", check=False)).strip():
                raise CodeError("Rien à proposer : aucune modification.")
            await self.git("push", "--quiet", "-u", "origin", branch)
        return branch

    async def revert(self, sha: str, label: str) -> str:
        """A branch from the latest main that undoes one merged commit, pushed; returns its name."""
        async with self.lock:
            await self.ensure()
            await self.git("fetch", "--quiet", "origin")
            await self.git("checkout", "--quiet", "-B", "main", "origin/main")
            await self.git("reset", "--quiet", "--hard", "origin/main")
            await self.git("clean", "-fdq")
            name = f"{BRANCH_PREFIX}annule-{label}-{time.strftime('%m%d-%H%M')}"
            await self.git("checkout", "--quiet", "-b", name)
            try:
                await self.git("revert", "--no-edit", sha)
            except CodeError:
                await self.git("revert", "--abort", check=False)
                await self.git("checkout", "--quiet", "main")
                raise CodeError("Annulation impossible telle quelle : d'autres changements ont touché les mêmes "
                                "lignes depuis. Défais-la à la main sur une nouvelle branche.") from None
            await self.git("push", "--quiet", "-u", "origin", name)
        return name

    async def on_marcel_branch(self) -> str:
        branch = await self.branch()
        if not branch.startswith(BRANCH_PREFIX):
            raise CodeError("Commence par marcel_code_commencer (une branche à toi, jamais main).")
        return branch


class GitHub:
    """The few GitHub calls Marcel's code tools need."""

    def __init__(self, repo: str, token: str):
        self.repo, self.token = repo, token

    async def call(self, method: str, path: str, **kwargs):
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28"}
        try:
            async with httpx.AsyncClient(base_url="https://api.github.com", timeout=20) as client:
                resp = await client.request(method, f"/repos/{self.repo}{path}", headers=headers, **kwargs)
        except httpx.HTTPError:
            raise CodeError("GitHub injoignable depuis le serveur.") from None
        if resp.status_code in (401, 403):
            raise CodeError("GitHub refuse la clé du serveur : il lui faut Contents et Pull requests en écriture.")
        if resp.status_code == 405:
            raise CodeError(f"GitHub refuse la fusion : {resp.json().get('message', '')}")
        if resp.status_code >= 400:
            raise CodeError(f"GitHub a refusé ({resp.status_code}) : {resp.text[:200]}")
        return resp.json() if resp.content else {}

    async def open_pull(self, branch: str, title: str, body: str) -> dict:
        existing = await self.call("GET", "/pulls", params={"head": f"{self.repo.split('/')[0]}:{branch}", "state": "open"})
        if existing:
            return existing[0]
        return await self.call("POST", "/pulls", json={"title": title, "head": branch, "base": "main", "body": body})

    async def pulls(self, state: str = "open") -> list[dict]:
        return await self.call("GET", "/pulls", params={"state": state, "per_page": 30})

    async def merge(self, number: int, title: str, sha: str = "") -> dict:
        """Squash merge; with sha, only if the branch is still what was checked."""
        return await self.call("PUT", f"/pulls/{number}/merge",
                               json={"merge_method": "squash", "commit_title": title} | ({"sha": sha} if sha else {}))

    async def checks(self, sha: str) -> tuple[str, list[dict]]:
        """Where the CI stands on a commit: "ok", "pending", "failed" or "none", and each check."""
        runs = (await self.call("GET", f"/commits/{sha}/check-runs", params={"per_page": 50})).get("check_runs", [])
        if not runs:
            return "none", []
        if any(r["status"] != "completed" for r in runs):
            return "pending", runs
        if any(r["conclusion"] not in ("success", "skipped", "neutral") for r in runs):
            return "failed", runs
        return "ok", runs

    async def job_log(self, job_id: int, lines: int = 60) -> str:
        """The end of a GitHub Actions job's log (a check run of a workflow is its job)."""
        headers = {"Authorization": f"Bearer {self.token}", "X-GitHub-Api-Version": "2022-11-28"}
        try:
            async with httpx.AsyncClient(base_url="https://api.github.com", timeout=30, follow_redirects=True) as client:
                resp = await client.get(f"/repos/{self.repo}/actions/jobs/{job_id}/logs", headers=headers)
        except httpx.HTTPError:
            return "(journal injoignable)"
        if resp.status_code >= 400:
            return f"(journal refusé par GitHub : {resp.status_code}, il faut Actions en lecture)"
        # Each line starts with a timestamp: "2026-10-24T13:00:00.0000000Z ".
        text = [re.sub(r"^\S+Z ", "", line) for line in resp.text.splitlines()]
        return "\n".join(text[-lines:])
