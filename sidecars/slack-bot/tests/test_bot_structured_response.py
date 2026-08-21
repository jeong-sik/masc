"""Bot-level tests for Slack structured GateResponse dispatch."""

from __future__ import annotations

import asyncio
import re
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

from src.bot import (  # noqa: E402
    BLOCK_ACTION_ID_PATTERN,
    SlackGateBot,
    button_content,
    button_idempotency_key,
)
from src.gate_client import GateClient, GateResponse  # noqa: E402


class _Client:
    def __init__(self) -> None:
        self.updates: list[dict[str, Any]] = []

    def chat_update(self, **kwargs: Any) -> None:
        self.updates.append(kwargs)


class _App:
    def __init__(self) -> None:
        self.client = _Client()


class _HandlerApp(_App):
    def __init__(self) -> None:
        super().__init__()
        self.action_matcher: Any = None
        self.action_handler: Any = None

    @staticmethod
    def _ignore_registration(_name: Any) -> Any:
        return lambda handler: handler

    event = _ignore_registration
    command = _ignore_registration

    def action(self, matcher: Any) -> Any:
        self.action_matcher = matcher

        def register(handler: Any) -> Any:
            self.action_handler = handler
            return handler

        return register

    def dispatch_action(
        self,
        action_id: str,
        *,
        ack: Any,
        body: dict[str, Any],
        say: Any,
    ) -> None:
        assert isinstance(self.action_matcher, re.Pattern)
        if self.action_matcher.search(action_id):
            self.action_handler(ack=ack, body=body, say=say)


class _Gate:
    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    async def send_slack_message(self, **kwargs: Any) -> GateResponse:
        self.calls.append(kwargs)
        return GateResponse(
            ok=True,
            keeper_name="sangsu",
            reply="handled",
            model_used="",
            duration_ms=0,
            tokens_used=0,
            error="",
            structured=None,
        )


def _bot() -> SlackGateBot:
    bot = cast(Any, SlackGateBot.__new__(SlackGateBot))
    bot._messages_processed = 0
    bot._messages_failed = 0
    bot._last_message_at = ""
    bot._bindings = {"C123": "sangsu"}
    bot.cfg = types.SimpleNamespace(default_keeper="sangsu")
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


def test_button_content_with_value() -> None:
    assert (
        button_content("approve_123", "task-123")
        == "[button] approve_123 value=task-123"
    )


def test_button_content_without_value() -> None:
    assert button_content("approve_123") == "[button] approve_123"


def test_button_content_empty_value() -> None:
    assert button_content("approve_123", "") == "[button] approve_123"


def test_button_idempotency_key_is_per_interaction() -> None:
    first = button_idempotency_key(
        channel_id="C123", action_id="approve_123", action_ts="171.001"
    )
    retry = button_idempotency_key(
        channel_id="C123", action_id="approve_123", action_ts="171.001"
    )
    second_click = button_idempotency_key(
        channel_id="C123", action_id="approve_123", action_ts="171.002"
    )

    assert first == retry
    assert first != second_click


def test_compiled_action_matcher_dispatches_and_preserves_retry_identity() -> None:
    bot = _bot()
    gate = _Gate()
    bot.gate = gate
    app = _HandlerApp()
    bot.register_handlers(cast(Any, app))
    acknowledgements: list[None] = []

    def body(action_ts: str) -> dict[str, Any]:
        return {
            "actions": [
                {
                    "action_id": "approve_123",
                    "action_ts": action_ts,
                    "value": "task-123",
                }
            ],
            "user": {"id": "U123", "username": "alice"},
            "channel": {"id": "C123"},
            "container": {"message_ts": "170.999"},
        }

    say = lambda *_args, **_kwargs: {"ts": "thinking.1"}
    ack = lambda: acknowledgements.append(None)
    app.dispatch_action("approve_123", ack=ack, body=body("171.001"), say=say)
    app.dispatch_action("approve_123", ack=ack, body=body("171.001"), say=say)
    app.dispatch_action("approve_123", ack=ack, body=body("171.002"), say=say)

    assert app.action_matcher is BLOCK_ACTION_ID_PATTERN
    assert len(acknowledgements) == 3
    assert [call["content"] for call in gate.calls] == [
        "[button] approve_123 value=task-123",
        "[button] approve_123 value=task-123",
        "[button] approve_123 value=task-123",
    ]
    assert gate.calls[0]["idempotency_key"] == gate.calls[1]["idempotency_key"]
    assert gate.calls[0]["idempotency_key"] != gate.calls[2]["idempotency_key"]
    assert gate.calls[0]["message_ts"] == "170.999"


def test_explicit_interaction_idempotency_key_reaches_gate_request() -> None:
    client = cast(Any, GateClient.__new__(GateClient))
    captured: list[dict[str, Any]] = []

    async def send_message(**kwargs: Any) -> GateResponse:
        captured.append(kwargs)
        return GateResponse(
            ok=True,
            keeper_name="sangsu",
            reply="handled",
            model_used="",
            duration_ms=0,
            tokens_used=0,
            error="",
            structured=None,
        )

    client.send_message = send_message
    response = asyncio.run(
        client.send_slack_message(
            keeper_name="sangsu",
            content="[button] approve_123 value=task-123",
            user_id="U123",
            username="alice",
            channel_id="C123",
            message_ts="170.999",
            idempotency_key="slack-action-C123-approve_123-171.001",
        )
    )

    assert response.ok
    assert captured[0]["idempotency_key"] == ("slack-action-C123-approve_123-171.001")


def test_message_idempotency_key_default_is_unchanged() -> None:
    client = cast(Any, GateClient.__new__(GateClient))
    captured: list[dict[str, Any]] = []

    async def send_message(**kwargs: Any) -> GateResponse:
        captured.append(kwargs)
        return GateResponse(
            ok=True,
            keeper_name="sangsu",
            reply="handled",
            model_used="",
            duration_ms=0,
            tokens_used=0,
            error="",
            structured=None,
        )

    client.send_message = send_message
    asyncio.run(
        client.send_slack_message(
            keeper_name="sangsu",
            content="hello",
            user_id="U123",
            username="alice",
            channel_id="C123",
            message_ts="170.999",
        )
    )

    assert captured[0]["idempotency_key"] == "slack-msg-C123-170.999"
