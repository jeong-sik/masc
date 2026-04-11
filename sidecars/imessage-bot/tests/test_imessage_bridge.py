from __future__ import annotations

import sqlite3
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from src.imessage_bridge import resolve_self_chat_guid, send_message


class SendMessageTests(unittest.TestCase):
    def test_resolve_self_chat_guid_returns_explicit_override(self) -> None:
        chat_guid = resolve_self_chat_guid("/tmp/does-not-matter.db", "self-guid")

        self.assertEqual(chat_guid, "self-guid")

    def test_resolve_self_chat_guid_detects_latest_self_chat(self) -> None:
        with TemporaryDirectory() as tmpdir:
            db_path = Path(tmpdir) / "chat.db"
            conn = sqlite3.connect(db_path)
            try:
                conn.execute(
                    "CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, account_login TEXT, service_name TEXT)"
                )
                conn.execute(
                    "CREATE TABLE message (ROWID INTEGER PRIMARY KEY, date INTEGER)"
                )
                conn.execute(
                    "CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)"
                )
                conn.execute(
                    "INSERT INTO chat VALUES (1, 'self-phone-guid', '+821029399460', 'P:+821029399460', 'iMessage')"
                )
                conn.execute(
                    "INSERT INTO chat VALUES (2, 'self-email-guid', 'forsyphilis@gmail.com', 'E:forsyphilis@gmail.com', 'iMessage')"
                )
                conn.execute("INSERT INTO message VALUES (1, 100)")
                conn.execute("INSERT INTO message VALUES (2, 200)")
                conn.execute("INSERT INTO chat_message_join VALUES (1, 1)")
                conn.execute("INSERT INTO chat_message_join VALUES (2, 2)")
                conn.commit()
            finally:
                conn.close()

            chat_guid = resolve_self_chat_guid(str(db_path))

        self.assertEqual(chat_guid, "self-email-guid")

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

    def test_send_message_requires_chat_guid_argument(self) -> None:
        with self.assertRaises(TypeError):
            send_message(text="hello")  # type: ignore[call-arg]

    @patch("src.imessage_bridge.subprocess.run")
    def test_send_message_rejects_blank_target(self, run_mock) -> None:
        ok = send_message(text="hello", chat_guid="")

        self.assertFalse(ok)
        run_mock.assert_not_called()
