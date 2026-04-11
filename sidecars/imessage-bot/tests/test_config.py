from __future__ import annotations

import unittest

from pydantic import ValidationError

from src.config import BotConfig


class BotConfigTests(unittest.TestCase):
    def test_reply_mode_is_normalized(self) -> None:
        cfg = BotConfig(reply_mode=" SOURCE-CHAT ")

        self.assertEqual(cfg.reply_mode, "source-chat")

    def test_reply_mode_rejects_invalid_values(self) -> None:
        with self.assertRaises(ValidationError):
            BotConfig(reply_mode="everyone")

    def test_self_chat_guid_is_trimmed(self) -> None:
        cfg = BotConfig(self_chat_guid=" any;-;forsyphilis@gmail.com  ")

        self.assertEqual(cfg.self_chat_guid, "any;-;forsyphilis@gmail.com")
