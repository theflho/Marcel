"""Marcel platform adapter: nothing in, POST out.

The Marcel app talks to Hermes through the API server; what Hermes sends on its own (cron results,
send_message) has nowhere to go there (api_server never pushes). This adapter is that way out, like
the Telegram one: POST {MARCEL_DELIVER_URL}/v1/hermes/deliver, and Marcel puts the text in the
conversation of the bot whose id is the chat id, with its notification.

Env (scoped per profile, so each profile delivers to its own bot): MARCEL_DELIVER_KEY (required,
Marcel's MCP token), MARCEL_DELIVER_URL (default http://127.0.0.1:8000), MARCEL_HOME_CHANNEL (the
profile's bot: ``marcel`` for the main profile, ``planning`` for marcel-planning…), where cron jobs
created from the app go (deliver=origin falls back to the home channel).

The key is kept off the attributes the multiplexer fingerprints (``token``…): every profile shares
it, and a shared token would park all but one adapter as a duplicate credential.
"""

import logging
from typing import Any, Optional

try:
    import httpx
    HTTPX_AVAILABLE = True
except ImportError:
    HTTPX_AVAILABLE = False
    httpx = None  # type: ignore[assignment]

from gateway.config import Platform, PlatformConfig
from gateway.platforms.base import BasePlatformAdapter, SendResult
from gateway.platforms._shared import get_scoped_secret, send_error, seed_extra_from_env
from gateway.platforms.send_targets import parse_nonempty

from .compat import skills_api_compat
from .progress import install_progress_previews
from .media import post_delivery

logger = logging.getLogger(__name__)

DEFAULT_URL = "http://127.0.0.1:8000"
MAX_MESSAGE_LENGTH = 20000
TIMEOUT = 15.0


def _setting(extra: dict, key: str, env: str, default: str = "") -> str:
    return str(extra.get(key) or get_scoped_secret(env, "") or default).strip()


def check_requirements() -> bool:
    return HTTPX_AVAILABLE and bool(get_scoped_secret("MARCEL_DELIVER_KEY", "").strip())


def validate_config(config) -> bool:
    return bool(_setting(getattr(config, "extra", {}) or {}, "deliver_key", "MARCEL_DELIVER_KEY"))


def is_connected(config) -> bool:
    return validate_config(config)


async def _post(url: str, key: str, bot: str, text: str, media_files=()) -> dict[str, Any]:
    paths = []
    for path in media_files:
        safe = BasePlatformAdapter.validate_media_delivery_path(path)
        if not safe:
            raise ValueError("Hermes refuse l'envoi de ce fichier")
        paths.append(safe)
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        return await post_delivery(client, url, key, bot, text[:MAX_MESSAGE_LENGTH], paths)


class MarcelAdapter(BasePlatformAdapter):
    MAX_MESSAGE_LENGTH = MAX_MESSAGE_LENGTH

    def __init__(self, config: PlatformConfig):
        super().__init__(config=config, platform=Platform("marcel"))
        extra = config.extra or {}
        self._deliver_url = _setting(extra, "deliver_url", "MARCEL_DELIVER_URL", DEFAULT_URL)
        self._deliver_key = _setting(extra, "deliver_key", "MARCEL_DELIVER_KEY")

    async def connect(self, *, is_reconnect: bool = False) -> bool:
        if not HTTPX_AVAILABLE or not self._deliver_key:
            logger.warning("[%s] httpx or MARCEL_DELIVER_KEY missing", self.name)
            return False
        self._mark_connected()
        self._wire_plugin_handlers(None)
        return True

    async def disconnect(self) -> None:
        self._mark_disconnected()

    async def send(self, chat_id: str, content: str, reply_to: Optional[str] = None,
                   metadata: Optional[dict[str, Any]] = None) -> SendResult:
        try:
            answer = await _post(self._deliver_url, self._deliver_key, chat_id, content)
        except Exception as error:
            logger.warning("[%s] delivery to %s failed: %s", self.name, chat_id, error)
            return SendResult(success=False, error=str(error))
        return SendResult(success=True, message_id=str(answer.get("id", "")))

    async def _send_file(self, chat_id: str, path: str, caption: Optional[str]) -> SendResult:
        try:
            answer = await _post(self._deliver_url, self._deliver_key, chat_id, caption or "", [path])
        except Exception as error:
            return SendResult(success=False, error=str(error))
        return SendResult(success=True, message_id=str(answer.get("id", "")))

    async def send_document(self, chat_id: str, file_path: str, caption: Optional[str] = None,
                            file_name: Optional[str] = None, reply_to: Optional[str] = None,
                            metadata: Optional[dict[str, Any]] = None, **kwargs) -> SendResult:
        return await self._send_file(chat_id, file_path, caption)

    async def send_image_file(self, chat_id: str, image_path: str, caption: Optional[str] = None,
                              reply_to: Optional[str] = None, metadata: Optional[dict[str, Any]] = None,
                              **kwargs) -> SendResult:
        return await self._send_file(chat_id, image_path, caption)

    async def send_voice(self, chat_id: str, audio_path: str, caption: Optional[str] = None,
                         reply_to: Optional[str] = None, metadata: Optional[dict[str, Any]] = None,
                         **kwargs) -> SendResult:
        return await self._send_file(chat_id, audio_path, caption)

    async def send_video(self, chat_id: str, video_path: str, caption: Optional[str] = None,
                         reply_to: Optional[str] = None, metadata: Optional[dict[str, Any]] = None,
                         **kwargs) -> SendResult:
        return await self._send_file(chat_id, video_path, caption)

    async def get_chat_info(self, chat_id: str) -> dict[str, Any]:
        return {"name": chat_id, "type": "dm"}


def _env_enablement() -> dict | None:
    if not get_scoped_secret("MARCEL_DELIVER_KEY", "").strip():
        return None
    return seed_extra_from_env((("MARCEL_DELIVER_URL", "deliver_url", lambda v: v.rstrip("/")),),
                               home_env="MARCEL_HOME_CHANNEL", home_default="marcel")


async def _standalone_send(pconfig, chat_id: str, message: str, *, thread_id: Optional[str] = None,
                           media_files: Optional[list[str]] = None, force_document: bool = False) -> dict[str, Any]:
    """Out-of-process delivery (cron / send_message when no gateway adapter is live)."""
    if not HTTPX_AVAILABLE:
        return send_error("marcel standalone send: httpx not installed")
    extra = getattr(pconfig, "extra", {}) or {}
    key = _setting(extra, "deliver_key", "MARCEL_DELIVER_KEY")
    if not key:
        return send_error("marcel standalone send: MARCEL_DELIVER_KEY not configured")
    bot = chat_id or _setting(extra, "", "MARCEL_HOME_CHANNEL", "marcel")
    try:
        answer = await _post(_setting(extra, "deliver_url", "MARCEL_DELIVER_URL", DEFAULT_URL), key, bot, message, media_files or [])
    except Exception as error:
        return send_error(f"marcel standalone send failed: {error}")
    return {"success": True, "platform": "marcel", "chat_id": bot, "message_id": str(answer.get("id", ""))}


def register(ctx) -> None:
    skills_api_compat()
    install_progress_previews()
    ctx.register_platform(
        target_ref_syntax_fn=parse_nonempty,
        name="marcel", label="Marcel", adapter_factory=lambda cfg: MarcelAdapter(cfg),
        dashboard_description="L'app Marcel (iPhone) : livre dans la conversation du bot de ce profil.",
        check_fn=check_requirements, validate_config=validate_config, is_connected=is_connected,
        required_env=["MARCEL_DELIVER_KEY"], install_hint="pip install httpx   # already a Hermes dependency",
        env_enablement_fn=_env_enablement,
        cron_deliver_env_var="MARCEL_HOME_CHANNEL",
        standalone_sender_fn=_standalone_send,
        max_message_length=MAX_MESSAGE_LENGTH, emoji="📱",
        pii_safe=True,
        platform_hint=(
            "You are delivering to the Marcel iPhone app, in the conversation of this profile's bot. "
            "Markdown is rendered. The user reads it later, with a notification: say what matters first."
        ))
