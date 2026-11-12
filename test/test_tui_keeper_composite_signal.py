#!/usr/bin/env python3
"""The Keeper detail reads its Keeper's composite again when the server
announces a change of that Keeper, and again after a failed read
(RFC-0480 L3).

The refresh cadence is pushed out of the test's lifetime, so every composite
read after the detail opens comes from an announcement or a failed read.
"""

import os
import sys
import threading
import time
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


COMPOSITE_PATH = "/api/v1/keepers/analyst/composite"


def composite_body() -> dict[str, object]:
    return {
        "keeper": "analyst",
        "phase": "running",
        "turn_phase": "idle",
        "idle_seconds": 3,
        "last_outcome": None,
    }


class CompositeHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(CompositeServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == COMPOSITE_PATH:
            phase = server.record(request.path)
            with server.condition:
                server.composite_times.append(time.monotonic())
                fail = server.composite_failures_left > 0
                if fail:
                    server.composite_failures_left -= 1
            if fail:
                sent = self.respond(503, {"error": "composite unavailable"})
            else:
                sent = self.respond(200, composite_body())
            if sent:
                server.responded(phase, request.path)
        else:
            super().do_GET()


class CompositeServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = CompositeHandler
        self.composite_times: list[float] = []
        self.composite_failures_left = 0


def composite_changed(keeper: str) -> dict[str, object]:
    return {"type": "keeper_composite_changed", "name": keeper, "ts_unix": 1.0}


class KeeperCompositeSignalTest(unittest.TestCase):
    binary = ""

    def run_detail(self, scenario: Callable[[CompositeServer, Callable[..., None]], None]) -> None:
        owed.ChatServer = CompositeServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def opened(server: owed.ChatServer, step: Callable[..., None]) -> None:
            composite = cast(CompositeServer, server)
            composite.set_phase("open")
            # Enter on a Keeper row opens the Story window of the list, which
            # reads no composite (RFC-0515); Right from it opens the detail,
            # whose Info tab does.
            step("keys", "\r")
            step("drain", 0.5)
            step("sequence", "\x1b[C")
            step(
                "wait",
                lambda: composite.response_count("open", COMPOSITE_PATH) >= 1,
                "the detail did not read its Keeper's composite",
            )
            step("drain", 1.0)
            scenario(composite, step)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), opened)

    def test_a_change_of_the_detail_keeper_is_read(self) -> None:
        def scenario(server: CompositeServer, step: Callable[..., None]) -> None:
            server.set_phase("other")
            server.events.put(composite_changed("someone-else"))
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 1,
                "the other Keeper's change was not sent",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("other", COMPOSITE_PATH), 0)
            server.set_phase("changed")
            server.events.put(composite_changed("analyst"))
            step(
                "wait",
                lambda: server.response_count("changed", COMPOSITE_PATH) == 1,
                "the detail Keeper's change did not cause a composite read",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("changed", COMPOSITE_PATH), 1)

        self.run_detail(scenario)

    def test_failed_composite_reads_are_read_again_with_growing_waits(self) -> None:
        def scenario(server: CompositeServer, step: Callable[..., None]) -> None:
            with server.condition:
                server.composite_failures_left = 2
                server.composite_times.clear()
            server.events.put(composite_changed("analyst"))
            step(
                "wait",
                lambda: len(server.composite_times) >= 3,
                "two failed composite reads were not followed by a third",
            )
            step("drain", 6.0)
            with server.condition:
                times = list(server.composite_times)
            # The third read succeeded, so nothing reads again.
            self.assertEqual(len(times), 3)
            first_wait = times[1] - times[0]
            second_wait = times[2] - times[1]
            self.assertGreater(first_wait, 1.0)
            self.assertGreater(second_wait, first_wait + 1.0)

        self.run_detail(scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_keeper_composite_signal.py /path/to/masc_tui.exe")
    KeeperCompositeSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
