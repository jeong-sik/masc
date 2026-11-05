#!/usr/bin/env python3
"""The Board list and hearth census read again when the server announces a
Board write while the Board is on screen, and again after a failed read
(RFC-0480 L4).

The TUI reads nothing on a clock, so every list read
after the Board opens comes from an announcement or a failed read.
"""

import os
import sys
import time
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_board_post_signal as board
import test_tui_chat_owed_history as owed


LIST_PATH = "/api/v1/board"
HEARTHS_PATH = "/api/v1/board/hearths"


class ListHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(ListServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == LIST_PATH:
            phase = server.record(request.path)
            with server.condition:
                server.list_times.append(time.monotonic())
                fail = server.list_failures_left > 0
                if fail:
                    server.list_failures_left -= 1
            if fail:
                sent = self.respond(503, {"error": "board unavailable"}, workspace_receipt=True)
            else:
                sent = self.respond(200, {"posts": [board.post()]}, workspace_receipt=True)
            if sent:
                server.responded(phase, request.path)
        elif request.path == HEARTHS_PATH:
            phase = server.record(request.path)
            if self.respond(200, {"hearths": []}, workspace_receipt=True):
                server.responded(phase, request.path)
        else:
            super().do_GET()


class ListServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = ListHandler
        self.list_times: list[float] = []
        self.list_failures_left = 0


class BoardListSignalTest(unittest.TestCase):
    binary = ""

    def run_list(self, scenario: Callable[[ListServer, Callable[..., None]], None]) -> None:
        owed.ChatServer = ListServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def opened(server: owed.ChatServer, step: Callable[..., None]) -> None:
            listing = cast(ListServer, server)
            listing.set_phase("open")
            # Keepers -> Usage -> Board.
            step("keys", "\t\t")
            step(
                "wait",
                lambda: listing.response_count("open", LIST_PATH) >= 1,
                "the Board did not read its list",
            )
            step("drain", 1.0)
            scenario(listing, step)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), opened)

    def test_a_board_write_reads_the_list_and_census(self) -> None:
        def scenario(server: ListServer, step: Callable[..., None]) -> None:
            server.set_phase("quiet")
            step("drain", 2.0)
            self.assertEqual(server.count("quiet", LIST_PATH), 0)
            server.set_phase("changed")
            server.events.put(board.post_changed("post-other"))
            step(
                "wait",
                lambda: (
                    server.response_count("changed", LIST_PATH) == 1
                    and server.response_count("changed", HEARTHS_PATH) == 1
                ),
                "a Board write did not read the list and the census",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("changed", LIST_PATH), 1)
            self.assertEqual(server.count("changed", HEARTHS_PATH), 1)

        self.run_list(scenario)

    def test_failed_list_reads_are_read_again_with_growing_waits(self) -> None:
        def scenario(server: ListServer, step: Callable[..., None]) -> None:
            with server.condition:
                server.list_failures_left = 2
                server.list_times.clear()
            server.events.put(board.comment_voted())
            step(
                "wait",
                lambda: len(server.list_times) >= 3,
                "two failed list reads were not followed by a third",
            )
            step("drain", 6.0)
            with server.condition:
                times = list(server.list_times)
            # The third read succeeded, so nothing reads again.
            self.assertEqual(len(times), 3)
            first_wait = times[1] - times[0]
            second_wait = times[2] - times[1]
            self.assertGreater(first_wait, 1.0)
            self.assertGreater(second_wait, first_wait + 1.0)

        self.run_list(scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_board_list_signal.py /path/to/masc_tui.exe")
    BoardListSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
