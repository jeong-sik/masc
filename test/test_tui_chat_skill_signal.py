#!/usr/bin/env python3
"""An open Keeper chat reads its history again when that Keeper's skill
activation ledger changes, because the history carries the exact Skill
evidence of its turns. Another Keeper's ledger change does not read it
(RFC-0483 L5).

The refresh cadence is pushed out of the test's lifetime, so every history
read after the chat opens comes from an announcement.
"""

import os
import sys
import unittest
from typing import Callable, cast

import test_tui_chat_owed_history as owed


def activations_changed(keeper: str) -> dict[str, object]:
    return {
        "type": "keeper_skill_activations_changed",
        "name": keeper,
        "trace_id": "trace-" + keeper,
        "ts_unix": 1.0,
    }


class ChatSkillSignalTest(unittest.TestCase):
    binary = ""

    def test_the_open_chats_ledger_change_reads_its_history(self) -> None:
        owed.ChatOwedHistoryTest.binary = self.binary

        def scenario(server: owed.ChatServer, step: Callable[..., None]) -> None:
            server.set_phase("open")
            step("keys", "c")
            step(
                "wait",
                lambda: server.response_count("open", owed.HISTORY_PATH) >= 1,
                "opening the chat did not read its history",
            )
            step("drain", 1.0)
            server.set_phase("other")
            server.events.put(activations_changed("bravo"))
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 1,
                "the other Keeper's change was not sent",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("other", owed.HISTORY_PATH), 0)
            server.set_phase("changed")
            server.events.put(activations_changed("analyst"))
            step(
                "wait",
                lambda: server.response_count("changed", owed.HISTORY_PATH) == 1,
                "the open chat's ledger change did not read its history",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("changed", owed.HISTORY_PATH), 1)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_chat_skill_signal.py /path/to/masc_tui.exe")
    ChatSkillSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
