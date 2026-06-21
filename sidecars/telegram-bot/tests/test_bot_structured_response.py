"""Bot-level tests for Telegram structured GateResponse dispatch."""

from __future__ import annotations

import asyncio
import sys
import types
from pathlib import Path
from types import SimpleNamespace
from typing import Any, cast

_sidecars_root = Path(__file__).resolve().parents[2]
_shared_root = _sidecars_root / "shared"
if str(_shared_root) not in sys.path:
    sys.path.insert(0, str(_shared_root))

_telegram = types.ModuleType("telegram")
_telegram_ext = types.ModuleType("telegram.ext")


class _MessageStub:
    pass


class _UpdateStub:
    pass


class _ApplicationStub:
    pass


class _HandlerStub:
    pass


setattr(_telegram, "Message", _MessageStub)
setattr(_telegram, "Update", _UpdateStub)
setattr(_telegram_ext, "Application", _ApplicationStub)
setattr(_telegram_ext, "CommandHandler", _HandlerStub)
setattr(_telegram_ext, "ContextTypes", SimpleNamespace(DEFAULT_TYPE=object))
setattr(_telegram_ext, "MessageHandler", _HandlerStub)
setattr(_telegram_ext, "filters", SimpleNamespace(TEXT=object(), COMMAND=object()))
sys.modules.setdefault("telegram", _telegram)
sys.modules.setdefault("telegram.ext", _telegram_ext)

_config = types.ModuleType("src.config")
setattr(_config, "get_config", lambda: SimpleNamespace())
setattr(_config, "TELEGRAM_MESSAGE_LIMIT", 4096)
sys.modules.setdefault("src.config", _config)

from src.bot import TelegramGateBot  # noqa: E402
from src.gate_client import GateResponse  # noqa: E402


class _ThinkingMessage:
    def __init__(self) -> None:
        self.edits: list[tuple[str, str | None]] = []

    async def edit_text(self, text: str, parse_mode: str | None = None) -> None:
        self.edits.append((text, parse_mode))


class _Chat:
    def __init__(self) -> None:
        self.id = 42
        self.thinking = _ThinkingMessage()
        self.sent: list[tuple[str, str | None]] = []

    async def send_message(
        self,
        text: str,
        parse_mode: str | None = None,
    ) -> _ThinkingMessage:
        if text == "...":
            return self.thinking
        self.sent.append((text, parse_mode))
        return self.thinking


class _Gate:
    async def send_telegram_message(self, **_kwargs: Any) -> GateResponse:
        return GateResponse(
            ok=True,
            keeper_name="sangsu",
            reply="",
            model_used="",
            duration_ms=0,
            tokens_used=0,
            error="",
            structured={"blocks": [{"t": "p", "html": "approved"}]},
        )


def _bot() -> TelegramGateBot:
    bot = cast(Any, TelegramGateBot.__new__(TelegramGateBot))
    bot.cfg = SimpleNamespace(default_keeper="sangsu")
    bot.gate = _Gate()
    bot._bindings = {}
    bot._messages_processed = 0
    bot._messages_failed = 0
    bot._last_message_at = ""

    async def no_stream(
        _update: object,
        _keeper: str,
        _text: str,
        _thinking_msg: _ThinkingMessage,
    ) -> bool:
        return False

    setattr(bot, "_stream_response", no_stream)
    return cast(TelegramGateBot, bot)


def test_handle_message_sends_structured_only_success() -> None:
    bot = _bot()
    chat = _Chat()
    update = SimpleNamespace(
        effective_chat=chat,
        effective_user=SimpleNamespace(id=7, username="operator"),
        message=SimpleNamespace(text="go", message_id=99),
    )

    asyncio.run(bot.handle_message(cast(Any, update), cast(Any, SimpleNamespace())))

    assert chat.thinking.edits == [("approved\n\n<i>sangsu</i>", "HTML")]
    assert chat.sent == []
    assert bot._messages_processed == 1
