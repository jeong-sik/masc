#!/usr/bin/env python3
"""The open chat reads its memory journal again when the server announces a
journal row for that Keeper, and not for another Keeper (RFC-0480 L2-pre).

The TUI reads nothing on a clock, so every journal
read after the chat opens comes from an announcement.
"""

import os
import sys
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


MEMORY_PATH = "/api/v1/keepers/analyst/memory-journal"


class MemoryHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(owed.ChatServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == MEMORY_PATH:
            phase = server.record(request.path)
            if self.respond(200, {"entries": []}):
                server.responded(phase, request.path)
        else:
            super().do_GET()


class MemoryServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = MemoryHandler


def journal_appended(keeper: str) -> dict[str, object]:
    return {"type": "keeper_memory_journal_appended", "name": keeper, "ts_unix": 1.0}


class ChatMemoryJournalSignalTest(unittest.TestCase):
    binary = ""

    def run_chat(self, scenario: Callable[[owed.ChatServer, Callable[..., None]], None]) -> None:
        owed.ChatServer = MemoryServer
        owed.ChatOwedHistoryTest.binary = self.binary
        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), scenario)

    def test_a_journal_row_of_the_open_keeper_is_read(self) -> None:
        def scenario(server: owed.ChatServer, step: Callable[..., None]) -> None:
            server.set_phase("open")
            step("keys", "c")
            step(
                "wait",
                lambda: server.response_count("open", MEMORY_PATH) >= 1,
                "the open chat did not read its memory journal",
            )
            step("drain", 1.0)
            server.set_phase("other")
            server.events.put(journal_appended("someone-else"))
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 1,
                "the other Keeper's journal event was not sent",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("other", MEMORY_PATH), 0)
            server.set_phase("memory")
            server.events.put(journal_appended("analyst"))
            step(
                "wait",
                lambda: server.response_count("memory", MEMORY_PATH) == 1,
                "the open Keeper's journal event did not cause a journal read",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("memory", MEMORY_PATH), 1)

        self.run_chat(scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_chat_memory_journal_signal.py /path/to/masc_tui.exe")
    ChatMemoryJournalSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
