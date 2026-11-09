#!/usr/bin/env python3
"""The Board list and hearth census read again when the server announces a
Board write while the Board is on screen, and again after a failed read
(RFC-0480 L4). A read on entering the Board that a newer refresh supersedes
before it answers is read again too (#48053).

The refresh cadence is pushed out of the test's lifetime, or reads no Board,
so every list read after the Board opens comes from an announcement, a failed
read or a superseded one.
"""

import os
import sys
import threading
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
                hold = server.hold_next_list
                server.hold_next_list = False
            if hold:
                server.list_held.set()
                server.release_list.wait(owed.WAIT_SECONDS)
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
        self.hold_next_list = False
        self.list_held = threading.Event()
        self.release_list = threading.Event()


class BoardListSignalTest(unittest.TestCase):
    binary = ""

    def run_list(self, scenario: Callable[[ListServer, Callable[..., None]], None]) -> None:
        owed.ChatServer = ListServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def opened(server: owed.ChatServer, step: Callable[..., None]) -> None:
            listing = cast(ListServer, server)
            listing.set_phase("open")
            # Keepers -> Board via the palette (#50465 took Board off the tab ring).
            step("keys", ":go Work / Board")
            step("drain", 0.3)
            step("keys", "\r")
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

    def test_an_entry_read_superseded_by_a_refresh_is_read_again(self) -> None:
        # A full refresh that starts while the entry read is held takes a
        # newer ticket, so the held answer is dropped. Since #48677 that
        # refresh asks for the Board itself, so the list is read again
        # while the old answer is still held, not after it is released.
        owed.ChatServer = ListServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def opened(server: owed.ChatServer, step: Callable[..., None]) -> None:
            listing = cast(ListServer, server)
            try:
                with listing.condition:
                    listing.hold_next_list = True
                listing.set_phase("open")
                # Keepers -> Board via the palette (#50465 took Board off the tab ring).
                step("keys", ":go Work / Board")
                step("drain", 0.3)
                step("keys", "\r")
                step("wait", listing.list_held.is_set, "the Board did not read its list")
                listing.set_phase("superseded")
                step(
                    "wait",
                    lambda: listing.response_count("superseded", "/health") >= 2,
                    "no refresh ran while the entry read was held",
                )
                step(
                    "wait",
                    lambda: listing.response_count("superseded", LIST_PATH) >= 1,
                    "the superseded entry read was not read again",
                )
                listing.set_phase("released")
                listing.release_list.set()
                step("drain", 2.0)
                # The re-read can itself be superseded by a later refresh and
                # read once more; it does not repeat without end.
                reads = listing.count("superseded", LIST_PATH) + listing.count(
                    "released", LIST_PATH
                )
                self.assertGreaterEqual(reads, 1)
                self.assertLessEqual(reads, 3)
            finally:
                listing.release_list.set()

        owed.ChatOwedHistoryTest.run_chat(
            cast(owed.ChatOwedHistoryTest, self), opened
        )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_board_list_signal.py /path/to/masc_tui.exe")
    BoardListSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
