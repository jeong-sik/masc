from __future__ import annotations

from datetime import datetime, timezone
import unittest
from unittest.mock import AsyncMock, patch

from src.bot import DEFAULT_KEEPER, IMessageBot
from src.gate_client import GateResponse
from src.imessage_bridge import InboundMessage


class IMessageBotTests(unittest.IsolatedAsyncioTestCase):
    @patch("src.bot.send_message", return_value=True)
    @patch("src.bot.GateClient")
    async def test_handle_message_replies_to_chat_guid(
        self,
        gate_client_cls,
        send_message_mock,
    ) -> None:
        gate_client = gate_client_cls.return_value
        gate_client.send_message = AsyncMock(
            return_value=GateResponse(
                ok=True,
                keeper_name=DEFAULT_KEEPER,
                reply="reply text",
                model_used="test-model",
                duration_ms=42,
                tokens_used=12,
                error="",
                structured=None,
            )
        )

        bot = IMessageBot()
        msg = InboundMessage(
            rowid=7,
            text="hello",
            date=datetime.now(tz=timezone.utc),
            service="iMessage",
            sender="+15551234567",
            chat_guid="iMessage;-;+15551234567",
            chat_identifier="chat123",
            display_name="Test",
        )

        ok = await bot._handle_message(msg)

        self.assertTrue(ok)
        gate_client.send_message.assert_awaited_once_with(
            keeper_name=DEFAULT_KEEPER,
            content="hello",
            sender="+15551234567",
            chat_id="chat123",
            message_rowid=7,
        )
        send_message_mock.assert_called_once_with(
            text="reply text",
            chat_guid="iMessage;-;+15551234567",
        )

    @patch("src.bot.send_message", return_value=True)
    @patch("src.bot.GateClient")
    async def test_handle_message_fails_closed_without_chat_guid(
        self,
        gate_client_cls,
        send_message_mock,
    ) -> None:
        gate_client = gate_client_cls.return_value
        gate_client.send_message = AsyncMock(
            return_value=GateResponse(
                ok=True,
                keeper_name=DEFAULT_KEEPER,
                reply="reply text",
                model_used="test-model",
                duration_ms=42,
                tokens_used=12,
                error="",
                structured=None,
            )
        )

        bot = IMessageBot()
        msg = InboundMessage(
            rowid=8,
            text="hello",
            date=datetime.now(tz=timezone.utc),
            service="iMessage",
            sender="+15557654321",
            chat_guid="",
            chat_identifier="chat456",
            display_name="Test",
        )

        ok = await bot._handle_message(msg)

        self.assertFalse(ok)
        send_message_mock.assert_not_called()
