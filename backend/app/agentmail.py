"""Marcel's own mailbox (AgentMail), for the accounts he creates himself.

It is his address, not the user's: sites send him their confirmation codes and links there.
Marcel only reads it (no sending: e-mails stay drafts, see the rules), and what he reads was
written by strangers, so it reaches the model wrapped as outside content.
"""

from __future__ import annotations

from urllib.parse import quote

import httpx

API = "https://api.agentmail.to/v0"
TIMEOUT = httpx.Timeout(connect=5, read=15, write=5, pool=5)
MAX_TEXT_CHARS = 4000


class MailboxError(Exception):
    pass


class Mailbox:
    def __init__(self, key: str, inbox: str = "") -> None:
        self.key = key
        self.inbox = inbox

    @property
    def connected(self) -> bool:
        return bool(self.key)

    async def _get(self, path: str, params: dict | None = None) -> dict:
        try:
            async with httpx.AsyncClient(timeout=TIMEOUT) as client:
                resp = await client.get(f"{API}{path}", params=params,
                                        headers={"Authorization": f"Bearer {self.key}"})
        except httpx.HTTPError as error:
            raise MailboxError(f"AgentMail injoignable : {error}") from error
        if resp.status_code != 200:
            raise MailboxError(f"AgentMail refuse ({resp.status_code}) : {resp.text[:200]}")
        return resp.json()

    async def address(self) -> str:
        """The inbox set in MARCEL_AGENTMAIL_INBOX, or the account's first one."""
        if not self.inbox:
            inboxes = (await self._get("/inboxes")).get("inboxes") or []
            if not inboxes:
                raise MailboxError("Aucune boîte AgentMail sur ce compte.")
            self.inbox = inboxes[0]["inbox_id"]
        return self.inbox

    async def messages(self, limit: int = 10) -> list[dict]:
        """The latest messages received, newest first: id, from, subject, time, preview, unread."""
        inbox = quote(await self.address(), safe="@")
        found = (await self._get(f"/inboxes/{inbox}/messages", {"limit": max(1, min(limit, 25))})).get("messages") or []
        return [{"id": m.get("message_id", ""), "from": m.get("from", ""), "subject": m.get("subject", ""),
                 "at": m.get("timestamp", ""), "preview": (m.get("preview") or "")[:300],
                 "unread": "unread" in (m.get("labels") or [])} for m in found]

    async def message(self, message_id: str) -> dict:
        """One message: from, subject, time and its text (trimmed)."""
        inbox = quote(await self.address(), safe="@")
        m = await self._get(f"/inboxes/{inbox}/messages/{quote(message_id, safe='')}")
        text = m.get("extracted_text") or m.get("text") or m.get("preview") or ""
        return {"id": m.get("message_id", message_id), "from": m.get("from", ""), "subject": m.get("subject", ""),
                "at": m.get("timestamp", ""), "text": text[:MAX_TEXT_CHARS]}
