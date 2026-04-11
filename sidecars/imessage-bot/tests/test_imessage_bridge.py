from __future__ import annotations

from types import SimpleNamespace
import unittest
from unittest.mock import patch

from src.imessage_bridge import send_message


class SendMessageTests(unittest.TestCase):
    @patch("src.imessage_bridge.subprocess.run")
    def test_send_message_targets_chat_guid_when_available(self, run_mock) -> None:
        run_mock.return_value = SimpleNamespace(returncode=0, stderr="")

        ok = send_message(
            text="hello",
            chat_guid="iMessage;-;+15551234567",
        )

        self.assertTrue(ok)
        command = run_mock.call_args.args[0]
        self.assertEqual(command[0:2], ["osascript", "-e"])
        self.assertIn("first chat whose id is", command[2])
        self.assertEqual(command[3:], ["iMessage;-;+15551234567", "hello"])

    @patch("src.imessage_bridge.subprocess.run")
    def test_send_message_rejects_missing_target(self, run_mock) -> None:
        ok = send_message(text="hello")

        self.assertFalse(ok)
        run_mock.assert_not_called()
