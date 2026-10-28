"""Ephemeral native approvals: only the exact live run/profile may be answered once or denied."""

import re
import uuid
from dataclasses import dataclass, field

from .server_log import mask


@dataclass
class PendingApproval:
    conversation: str
    url: str
    headers: dict = field(repr=False)
    run: str = ""
    fields: dict = field(default_factory=dict)
    busy: bool = False


class HermesApprovals:
    def __init__(self):
        self.pending: dict[str, PendingApproval] = {}

    def add(self, event: dict, conversation: str, url: str, headers: dict) -> dict:
        run = event.get("run_id", "")
        if not isinstance(run, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,200}", run):
            raise ValueError("missing native run id")
        fields = {key: event[key] for key in ("request_id", "execution_generation") if key in event}
        if "request_id" in fields and (not isinstance(fields["request_id"], str) or not fields["request_id"]):
            raise ValueError("invalid native approval id")
        action = "hermes-approval-" + uuid.uuid4().hex
        self.pending[action] = PendingApproval(conversation, url, dict(headers), run, fields)
        detail = str(event.get("command") or event.get("description") or event.get("reason") or
                     "Hermes demande ton accord pour poursuivre cette action.")
        return {"id": action, "name": "Validation Hermes", "detail": mask(detail)[:2000], "status": "pending"}

    def discard(self, actions):
        for action in actions:
            self.pending.pop(action, None)
