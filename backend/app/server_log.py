"""The server's recent log lines, kept in memory so Marcel can read them (marcel_journaux).

Marcel has no shell on the VPS: this is how he sees why something failed. Secrets are masked
before a line is kept (every environment value whose name says key, token, secret or password),
and nothing is written to disk here.
"""

from __future__ import annotations

import logging
import os
import re
import time
from collections import deque

MAX_LINES = 1000
SECRET_NAME = re.compile(r"KEY|TOKEN|SECRET|PASSWORD|PASS\b", re.IGNORECASE)


def secret_values() -> list[str]:
    return sorted({v for k, v in os.environ.items() if SECRET_NAME.search(k) and len(v) >= 8}, key=len, reverse=True)


def mask(text: str, secrets: list[str] | None = None) -> str:
    for value in secrets if secrets is not None else secret_values():
        text = text.replace(value, "***")
    # Bearer tokens and keys that were never in the environment (a header copied into an error…).
    return re.sub(r"(?i)(bearer\s+|basic\s+|api[_-]?key[=:\s]+)[A-Za-z0-9._~+/=-]{12,}", r"\1***", text)


class RingHandler(logging.Handler):
    def __init__(self):
        super().__init__(logging.INFO)
        self.lines: deque[tuple[float, str, str, str]] = deque(maxlen=MAX_LINES)
        self.secrets = secret_values()

    def emit(self, record: logging.LogRecord) -> None:
        try:
            text = record.getMessage()
            if record.exc_info:
                text += "\n" + logging.Formatter().formatException(record.exc_info)
            self.lines.append((record.created, record.levelname, record.name, mask(text, self.secrets)))
        except Exception:  # a log line must never break the server
            pass

    def tail(self, count: int = 80, level: str = "", search: str = "") -> str:
        wanted = logging.getLevelName(level.upper()) if level else logging.INFO
        wanted = wanted if isinstance(wanted, int) else logging.INFO
        found = [line for line in self.lines
                 if logging.getLevelName(line[1]) >= wanted and (not search or search.lower() in line[3].lower())]
        return "\n".join(f"{time.strftime('%d/%m %H:%M:%S', time.localtime(at))} {lvl} {name}: {text}"
                         for at, lvl, name, text in found[-count:])


handler = RingHandler()


def install() -> None:
    """Keeps the lines of Marcel, uvicorn and the libraries from INFO up (access lines excepted)."""
    logging.getLogger().addHandler(handler)
    logging.getLogger("marcel").setLevel(logging.INFO)
    # uvicorn's loggers don't reach the root one; uvicorn.error goes through "uvicorn".
    logging.getLogger("uvicorn").addHandler(handler)
