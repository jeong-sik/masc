"""Bot-level tests for Slack structured GateResponse dispatch."""

from __future__ import annotations

import sys
import types
from pathlib import Path
from typing import Any, cast

_sidecars_root = Path(__file__).resolve().parents[2]
_shared_root = _sidecars_root / "shared"
if str(_shared_root) not in sys.path:
    sys.path.insert(0, str(_shared_root))

_slack_bolt = types.ModuleType("slack_bolt")
_socket_mode = types.ModuleType("slack_bolt.adapter.socket_mode")


class _AppStub:
    pass


class _SocketModeHandlerStub:
    pass


setattr(_slack_bolt, "App", _AppStub)
setattr(_socket_mode, "SocketModeHandler", _SocketModeHandlerStub)
sys.modules.setdefault("slack_bolt", _slack_bolt)
sys.modules.setdefault("slack_bolt.adapter", types.ModuleType("slack_bolt.adapter"))
sys.modules.setdefault("slack_bolt.adapter.socket_mode", _socket_mode)

_config = types.ModuleType("src.config")
setattr(_config, "get_config", lambda: types.SimpleNamespace())
sys.modules.setdefault("src.config", _config)

from src.bot import SlackGateBot  # noqa: E402
from src.gate_client import GateResponse  # noqa: E402


class _Client:
    def __init__(self) -> None:
        self.updates: list[dict[str, Any]] = []

    def chat_update(self, **kwargs: Any) -> None:
        self.updates.append(kwargs)


class _App:
    def __init__(self) -> None:
        self.client = _Client()


def _bot() -> SlackGateBot:
    bot = cast(Any, SlackGateBot.__new__(SlackGateBot))
    bot._messages_processed = 0
    bot._messages_failed = 0
    bot._last_message_at = ""
    return cast(SlackGateBot, bot)


def test_handle_response_sends_structured_only_success() -> None:
    bot = _bot()
    app = _App()
    say_calls: list[dict[str, Any]] = []
    response = GateResponse(
        ok=True,
        keeper_name="sangsu",
        reply="",
        model_used="",
        duration_ms=0,
        tokens_used=0,
        error="",
        structured={"blocks": [{"t": "p", "html": "approved"}]},
    )

    bot._handle_response(
        response=response,
        say=lambda **kwargs: say_calls.append(kwargs),
        app=app,
        channel_id="C123",
        thinking_ts="123.456",
    )

    assert say_calls == []
    assert app.client.updates[0]["text"] == "approved"
    assert app.client.updates[0]["blocks"][0]["text"]["text"] == "approved"
    assert bot._messages_processed == 1
