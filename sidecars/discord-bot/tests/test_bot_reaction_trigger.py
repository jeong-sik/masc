"""Tests for Discord reaction trigger + busy hold + gap drain."""

from __future__ import annotations

import datetime
from typing import Any
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from src.bot import GateBot
from src.gate_client import GateResponse


class _AsyncIter:
    """Helper to mock discord.py history() async generator."""

    def __init__(self, items: list[Any]) -> None:
        self._items = items

    def __aiter__(self) -> _AsyncIter:
        return self

    async def __anext__(self) -> Any:
        if not self._items:
            raise StopAsyncIteration
        return self._items.pop(0)


@pytest.fixture
def bot() -> GateBot:
    with (
        patch("src.bot.GateClient") as mock_gate,
        patch("src.bot.migrate_legacy_runtime_files"),
        patch("src.bot.get_config") as mock_cfg,
        patch("src.bot.BindingStore") as mock_bs,
        patch("src.bot.BindingAuditStore"),
        patch("src.bot.StatusStore"),
        patch("src.bot.NamesStore"),
    ):
        cfg = MagicMock()
        cfg.discord_bot_token = "test-token"
        cfg.gate_base_url = "http://localhost:8935"
        cfg.gate_api_token = ""
        cfg.gate_origin.return_value = "http://localhost:8935"
        cfg.gate_timeout_sec = 120
        cfg.gate_breaker_failure_threshold = 3
        cfg.gate_breaker_reset_sec = 30
        cfg.status_cache_ttl_sec = 15
        cfg.keeper_cache_ttl_sec = 30
        cfg.discord_keeper_map = "{}"
        cfg.discord_admin_role_id = ""
        cfg.status_heartbeat_sec = 10
        cfg.discord_reaction_trigger_emoji = "🤖"
        cfg.discord_busy_debounce_sec = 0
        cfg.discord_batch_max_messages = 50
        cfg.discord_batch_gap_window_sec = 1800
        cfg.keeper_map.return_value = {}
        mock_cfg.return_value = cfg
        # binding_store.load() returns None → keeper_map() path
        mock_bs.return_value.load.return_value = None
        mock_bs.return_value.modified_time_ns.return_value = 0
        mock_gate_instance = MagicMock()
        mock_gate.return_value = mock_gate_instance
        instance = GateBot()
        instance._pending = {}
        instance._processing = {}
        instance._last_response_ts = {}
        instance.keeper_bindings = {}
        yield instance


@pytest.mark.asyncio
async def test_drain_pending_calls_stream_when_history_has_messages(bot: GateBot) -> None:
    """When history has messages, _drain_pending streams instead of send_message."""
    channel = MagicMock()
    channel.id = 42
    channel.typing = MagicMock(return_value=AsyncMock(__aenter__=AsyncMock(return_value=None), __aexit__=AsyncMock(return_value=None)))
    msg = MagicMock()
    msg.id = 123
    msg.content = "hello"
    msg.author = MagicMock()
    msg.author.id = 1
    msg.author.bot = False
    msg.author.display_name = "user#1"
    # history() must return async iterable directly (not a coroutine)
    channel.history = MagicMock(return_value=_AsyncIter([msg]))

    bot.gate.stream_message = AsyncMock(return_value=_AsyncIter(["delta"]))
    bot._stream_to_channel = AsyncMock(return_value=True)  # type: ignore[method-assign]

    await bot._drain_pending(
        channel=channel,
        keeper_name="keeper-test",
        trigger_msg_id=99,
        trigger_user_id="1",
        trigger_user_name="user#1",
    )

    bot._stream_to_channel.assert_awaited_once()
    bot.gate.send_message.assert_not_called()


@pytest.mark.asyncio
async def test_on_message_pends_when_processing_locked(bot: GateBot) -> None:
    """When lock is held, on_message stores pending message instead of processing."""
    import asyncio

    bot._processing[42] = asyncio.Lock()
    await bot._processing[42].acquire()

    message = MagicMock()
    message.author = MagicMock()
    message.author.id = 1
    message.author.bot = False
    message.author.__str__ = MagicMock(return_value="user#1")
    message.channel = MagicMock()
    message.channel.id = 42
    message.content = "hello"
    message.id = 100
    message.attachments = []
    message.guild = MagicMock()

    with patch.object(bot, "_resolve_keeper_for_channel", return_value="keeper-test"):
        await bot.on_message(message)

    assert 42 in bot._pending
    assert len(bot._pending[42]) == 1
    assert bot._pending[42][0][0] == 100
    bot._processing[42].release()


@pytest.mark.asyncio
async def test_drain_pending_uses_idempotency_key_format(bot: GateBot) -> None:
    """_drain_pending builds idempotency key as discord-batch-{msg_id}-{drain_count}."""
    channel = MagicMock()
    channel.id = 42
    channel.typing = MagicMock(return_value=AsyncMock(__aenter__=AsyncMock(return_value=None), __aexit__=AsyncMock(return_value=None)))
    msg = MagicMock()
    msg.id = 200
    msg.content = "hi"
    msg.author = MagicMock()
    msg.author.id = 2
    msg.author.bot = False
    msg.author.display_name = "tester"
    channel.history = MagicMock(return_value=_AsyncIter([msg]))

    bot.gate.send_message = AsyncMock(
        return_value=GateResponse(ok=True, keeper_name="keeper-test", reply="ok", model_used="", duration_ms=0, tokens_used=0, error="", structured=None)
    )
    bot._send_response = AsyncMock()  # type: ignore[method-assign]
    # stream returns False so send_message fallback is triggered
    bot._stream_to_channel = AsyncMock(return_value=False)  # type: ignore[method-assign]

    await bot._drain_pending(
        channel=channel,
        keeper_name="keeper-test",
        trigger_msg_id=99,
        trigger_user_id="1",
        trigger_user_name="user#1",
    )

    call_kwargs = bot.gate.send_message.await_args.kwargs
    assert call_kwargs["idempotency_key"] == "discord-batch-99-1"
