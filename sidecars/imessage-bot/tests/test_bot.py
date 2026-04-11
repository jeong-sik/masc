from __future__ import annotations

from datetime import datetime, timezone
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

from src.bot import DEFAULT_KEEPER, IMessageBot
from src.gate_client import GateResponse
from src.imessage_bridge import InboundMessage


class IMessageBotTests(unittest.IsolatedAsyncioTestCase):
    def _config(self, *, reply_mode: str = "self-chat", self_chat_guid: str = ""):
        return SimpleNamespace(
            status_path="/tmp/imessage-status.json",
            binding_store_path="/tmp/imessage-bindings.json",
            chat_db_path="/tmp/chat.db",
            poll_interval_sec=2.0,
            gate_base_url="http://127.0.0.1:8935",
            reply_mode=reply_mode,
            self_chat_guid=self_chat_guid,
        )

    @patch("src.bot.send_message", return_value=True)
    @patch("src.bot.resolve_self_chat_guid", return_value="self-guid")
    @patch("src.bot.GateClient")
    @patch("src.bot.get_config")
    async def test_handle_message_replies_to_chat_guid(
        self,
        get_config_mock,
        gate_client_cls,
        resolve_self_chat_guid_mock,
        send_message_mock,
    ) -> None:
        get_config_mock.return_value = self._config()
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
            chat_guid="source-guid",
            chat_identifier="chat123",
            display_name="Test",
        )

        ok = await bot._handle_message(msg)

        self.assertTrue(ok)
        resolve_self_chat_guid_mock.assert_called_once_with("/tmp/chat.db", "")
        gate_client.send_message.assert_awaited_once_with(
            keeper_name=DEFAULT_KEEPER,
            content="hello",
            sender="+15551234567",
            chat_id="chat123",
            message_rowid=7,
        )
        send_message_mock.assert_called_once_with(
            text="reply text",
            chat_guid="self-guid",
        )

    @patch("src.bot.send_message", return_value=True)
    @patch("src.bot.resolve_self_chat_guid", return_value="")
    @patch("src.bot.GateClient")
    @patch("src.bot.get_config")
    async def test_handle_message_skips_reply_without_self_chat_guid(
        self,
        get_config_mock,
        gate_client_cls,
        resolve_self_chat_guid_mock,
        send_message_mock,
    ) -> None:
        get_config_mock.return_value = self._config()
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
            sender="+15557654321",
            chat_guid="source-guid",
            chat_identifier="chat456",
            display_name="Test",
        )

        ok = await bot._handle_message(msg)

        self.assertTrue(ok)
        self.assertEqual(resolve_self_chat_guid_mock.call_count, 2)
        send_message_mock.assert_not_called()
        self.assertEqual(bot._messages_processed, 1)
        self.assertEqual(bot._messages_failed, 1)

    @patch("src.bot.send_message", return_value=True)
    @patch("src.bot.resolve_self_chat_guid", return_value="")
    @patch("src.bot.GateClient")
    @patch("src.bot.get_config")
    async def test_handle_message_skips_reply_without_source_chat_guid(
        self,
        get_config_mock,
        gate_client_cls,
        resolve_self_chat_guid_mock,
        send_message_mock,
    ) -> None:
        get_config_mock.return_value = self._config(reply_mode="source-chat")
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

        self.assertTrue(ok)
        resolve_self_chat_guid_mock.assert_not_called()
        send_message_mock.assert_not_called()
        self.assertEqual(bot._messages_processed, 1)
        self.assertEqual(bot._messages_failed, 1)

    @patch("src.bot.send_message", return_value=True)
    @patch("src.bot.resolve_self_chat_guid", return_value="")
    @patch("src.bot.GateClient")
    @patch("src.bot.get_config")
    async def test_handle_message_replies_to_source_chat_guid_in_source_chat_mode(
        self,
        get_config_mock,
        gate_client_cls,
        resolve_self_chat_guid_mock,
        send_message_mock,
    ) -> None:
        get_config_mock.return_value = self._config(reply_mode="source-chat")
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
            rowid=9,
            text="hello",
            date=datetime.now(tz=timezone.utc),
            service="iMessage",
            sender="+15550001111",
            chat_guid="source-guid",
            chat_identifier="chat789",
            display_name="Test",
        )

        ok = await bot._handle_message(msg)

        self.assertTrue(ok)
        resolve_self_chat_guid_mock.assert_not_called()
        send_message_mock.assert_called_once_with(
            text="reply text",
            chat_guid="source-guid",
        )
