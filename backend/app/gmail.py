"""Gmail, read only: Marcel can look at recent e-mails, never send, delete or change one.

The guarantee comes from Google, not from a prompt: the only scope ever requested is
gmail.readonly, and a token granted anything more is refused. Connecting is done once on the
VPS (python -m app.gmail_auth); the token stays in MARCEL_DATA_DIR and refreshes itself.

When the user's message is about e-mail, the sender, subject and snippet of the latest messages
go with the mission (never the full bodies).
"""

import asyncio
import base64
import hashlib
import json
import re
import secrets
import time
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlparse

import httpx

SCOPE = "https://www.googleapis.com/auth/gmail.readonly"
AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
REVOKE_URL = "https://oauth2.googleapis.com/revoke"
API_URL = "https://gmail.googleapis.com/gmail/v1/users/me"
# Google's flow for apps without a web server: the browser lands on this address, which fails,
# and the user copies the address (it holds the code).
REDIRECT_URI = "http://localhost:1"
# Messages that are about e-mail bring recent ones into the mission.
MAIL_WORDS = re.compile(r"\b(e-?mails?|mails?|courriels?|bo[iî]te de r[ée]ception|inbox|gmail|"
                        r"m'a (?:[ée]crit|r[ée]pondu)|messages? re[cç]us?)\b", re.IGNORECASE)
DEFAULT_QUERY = "newer_than:7d -category:promotions -category:social"


class GmailExpired(Exception):
    """Google withdrew the access (every 7 days while the Google app stays in "Test")."""


class GmailRefused(Exception):
    """Google refused the request; the message is Google's own explanation."""


def check(resp: httpx.Response) -> None:
    """Raises with Google's explanation (e.g. "Gmail API has not been used in project…")."""
    if resp.status_code in (401, 403):
        try:
            message = resp.json()["error"]["message"]
        except (ValueError, KeyError, TypeError):
            message = resp.text[:300]
        raise GmailRefused(message)
    resp.raise_for_status()


class Gmail:
    def __init__(self, data_dir: Path, client_id: str, client_secret: str):
        self.client_id, self.client_secret = client_id, client_secret
        self._token_path = data_dir / "google_token.json"
        self._pending_path = data_dir / "google_oauth_pending.json"
        self._lock = asyncio.Lock()

    @property
    def configured(self) -> bool:
        return bool(self.client_id and self.client_secret)

    @property
    def connected(self) -> bool:
        return self.configured and self._token_path.exists()

    # MARK: Connecting (once, from the VPS)

    def auth_url(self) -> str:
        """The address to open in a browser to allow read-only access (PKCE, offline)."""
        verifier = secrets.token_urlsafe(64)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        state = secrets.token_urlsafe(16)
        self._write(self._pending_path, {"verifier": verifier, "state": state})
        return AUTH_URL + "?" + urlencode({
            "client_id": self.client_id, "redirect_uri": REDIRECT_URI, "response_type": "code",
            "scope": SCOPE, "access_type": "offline", "prompt": "consent",
            "code_challenge": challenge, "code_challenge_method": "S256", "state": state,
        })

    async def connect(self, pasted: str) -> None:
        """Exchanges the address (or code) the user pasted for a read-only token."""
        pending = json.loads(self._pending_path.read_text())
        code, state = parse_pasted(pasted)
        if state and state != pending["state"]:
            raise ValueError("Cette adresse vient d'une ancienne demande : relance la connexion.")
        async with httpx.AsyncClient(timeout=20) as client:
            resp = await client.post(TOKEN_URL, data={
                "code": code, "client_id": self.client_id, "client_secret": self.client_secret,
                "redirect_uri": REDIRECT_URI, "grant_type": "authorization_code",
                "code_verifier": pending["verifier"]})
        if resp.status_code != 200:
            raise ValueError(f"Google a refusé le code : {resp.text[:200]}")
        token = resp.json()
        granted = set(token.get("scope", "").split())
        if granted != {SCOPE}:
            # Anything beyond reading is refused, even if Google granted it.
            await self._revoke(token.get("refresh_token") or token.get("access_token"))
            raise ValueError(f"Autorisations inattendues ({', '.join(sorted(granted))}) : connexion refusée.")
        if not token.get("refresh_token"):
            raise ValueError("Google n'a pas donné d'accès durable : relance la connexion.")
        self._save(token)
        self._pending_path.unlink(missing_ok=True)

    async def disconnect(self) -> None:
        if self._token_path.exists():
            token = json.loads(self._token_path.read_text())
            await self._revoke(token.get("refresh_token"))
            self._token_path.unlink()

    # MARK: Reading

    async def recent(self, limit: int = 15, query: str = DEFAULT_QUERY) -> list[dict]:
        """Sender, subject, date and snippet of the latest messages matching `query`."""
        headers = {"Authorization": f"Bearer {await self._access_token()}"}
        async with httpx.AsyncClient(timeout=15, headers=headers) as client:
            resp = await client.get(f"{API_URL}/messages", params={"q": query, "maxResults": limit})
            check(resp)
            ids = [m["id"] for m in resp.json().get("messages", [])]

            async def one(message_id: str) -> dict:
                r = await client.get(f"{API_URL}/messages/{message_id}", params={
                    "format": "metadata", "metadataHeaders": ["From", "Subject", "Date"]})
                check(r)
                data = r.json()
                fields = {h["name"]: h["value"] for h in data.get("payload", {}).get("headers", [])}
                return {"from": fields.get("From", ""), "subject": fields.get("Subject", "(sans objet)"),
                        "date": fields.get("Date", ""), "snippet": data.get("snippet", ""),
                        "unread": "UNREAD" in data.get("labelIds", [])}

            return list(await asyncio.gather(*(one(i) for i in ids)))

    @staticmethod
    def context(mails: list[dict]) -> str:
        if not mails:
            return "Boîte mail de l'utilisateur (lecture seule) : aucun e-mail récent."
        lines = [f"- {'[non lu] ' if m['unread'] else ''}{m['date'][:22]} · {m['from']} · {m['subject']} — {m['snippet'][:200]}"
                 for m in mails]
        return ("Derniers e-mails de l'utilisateur (lecture seule : tu ne peux ni envoyer, ni supprimer, "
                "ni modifier ; pour répondre, propose un brouillon) :\n" + "\n".join(lines))

    # MARK: Token

    async def _access_token(self) -> str:
        async with self._lock:
            token = json.loads(self._token_path.read_text())
            if token.get("access_token") and token.get("expires_at", 0) > time.time() + 60:
                return token["access_token"]
            async with httpx.AsyncClient(timeout=15) as client:
                resp = await client.post(TOKEN_URL, data={
                    "client_id": self.client_id, "client_secret": self.client_secret,
                    "refresh_token": token["refresh_token"], "grant_type": "refresh_token"})
            if resp.status_code == 400 and "invalid_grant" in resp.text:
                self._token_path.unlink(missing_ok=True)
                raise GmailExpired()
            resp.raise_for_status()
            fresh = resp.json()
            token.update(access_token=fresh["access_token"], expires_at=time.time() + int(fresh.get("expires_in", 3600)))
            self._write(self._token_path, token)
            return token["access_token"]

    def _save(self, token: dict) -> None:
        self._write(self._token_path, {
            "refresh_token": token["refresh_token"], "access_token": token.get("access_token"),
            "expires_at": time.time() + int(token.get("expires_in", 3600)), "scope": SCOPE})

    @staticmethod
    def _write(path: Path, data: dict) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch(mode=0o600, exist_ok=True)
        path.write_text(json.dumps(data))

    @staticmethod
    async def _revoke(token: str | None) -> None:
        if not token:
            return
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                await client.post(REVOKE_URL, data={"token": token})
        except httpx.HTTPError:
            pass


def parse_pasted(pasted: str) -> tuple[str, str | None]:
    """The code (and state) from the address the browser landed on, or a bare code."""
    pasted = pasted.strip()
    if pasted.startswith("http"):
        query = parse_qs(urlparse(pasted).query)
        if "error" in query:
            raise ValueError(f"Google a refusé : {query['error'][0]}")
        if "code" not in query:
            raise ValueError("Pas de code dans cette adresse : copie toute l'adresse de la page qui ne s'ouvre pas.")
        return query["code"][0], query.get("state", [None])[0]
    if not pasted:
        raise ValueError("Rien n'a été collé.")
    return pasted, None
