#!/usr/bin/env python3
"""The questions put to the operator read again when the server announces a
change to a Keeper's or an installation's question log, and again after a
failed read (RFC-0480 L8).

The refresh cadence is pushed out of the test's lifetime, so every question
read after the workspace is admitted comes from an announcement or a failed
read.
"""

import os
import sys
import time
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


KEEPER_ASKS_PATH = "/api/v1/keepers/asks"
INSTALLATION_ASKS_PATH = "/api/v1/lane-addons/asks"


class AsksHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(AsksServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == KEEPER_ASKS_PATH:
            phase = server.record(request.path)
            with server.condition:
                server.asks_times.append(time.monotonic())
                fail = server.asks_failures_left > 0
                if fail:
                    server.asks_failures_left -= 1
            if fail:
                sent = self.respond(503, {"error": "questions unavailable"})
            else:
                sent = self.respond(
                    200,
                    {
                        "state_ready": True,
                        "workspace": {
                            "base_path": server.base,
                            "masc_root": server.base + "/.masc",
                        },
                        "keeper": None,
                        "open_count": 0,
                        "asks": [],
                    },
                )
            if sent:
                server.responded(phase, request.path)
        elif request.path == INSTALLATION_ASKS_PATH:
            phase = server.record(request.path)
            if self.respond(200, {"asks": []}):
                server.responded(phase, request.path)
        else:
            super().do_GET()


class AsksServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = AsksHandler
        self.asks_times: list[float] = []
        self.asks_failures_left = 0


def keeper_asks_changed() -> dict[str, object]:
    return {"type": "keeper_asks_changed", "name": "analyst"}


def installation_asks_changed() -> dict[str, object]:
    return {"type": "lane_addon_asks_changed", "declaration_id": "quiz"}


def held_call_changed() -> dict[str, object]:
    return {"type": "keeper_tool_approval_waits_changed", "name": "analyst"}


class AsksSignalTest(unittest.TestCase):
    binary = ""

    def run_asks(self, scenario: Callable[[AsksServer, Callable[..., None]], None]) -> None:
        owed.ChatServer = AsksServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def admitted(server: owed.ChatServer, step: Callable[..., None]) -> None:
            asks = cast(AsksServer, server)
            step("drain", 1.0)
            scenario(asks, step)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), admitted)

    def test_a_question_change_reads_the_questions(self) -> None:
        def scenario(server: AsksServer, step: Callable[..., None]) -> None:
            server.set_phase("other")
            server.events.put(held_call_changed())
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 1,
                "the held call change was not sent",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("other", KEEPER_ASKS_PATH), 0)
            for phase, event in (
                ("keeper", keeper_asks_changed()),
                ("installation", installation_asks_changed()),
            ):
                server.set_phase(phase)
                server.events.put(event)
                step(
                    "wait",
                    lambda: server.response_count(phase, INSTALLATION_ASKS_PATH) == 1,
                    f"a {phase} question change did not read the questions",
                )
                step("drain", 1.5)
                self.assertEqual(server.count(phase, KEEPER_ASKS_PATH), 1)
                self.assertEqual(server.count(phase, INSTALLATION_ASKS_PATH), 1)

        self.run_asks(scenario)

    def test_failed_question_reads_are_read_again_with_growing_waits(self) -> None:
        def scenario(server: AsksServer, step: Callable[..., None]) -> None:
            with server.condition:
                server.asks_failures_left = 2
                server.asks_times.clear()
            server.events.put(keeper_asks_changed())
            step(
                "wait",
                lambda: len(server.asks_times) >= 3,
                "two failed question reads were not followed by a third",
            )
            step("drain", 6.0)
            with server.condition:
                times = list(server.asks_times)
            # The third read succeeded, so nothing reads again.
            self.assertEqual(len(times), 3)
            first_wait = times[1] - times[0]
            second_wait = times[2] - times[1]
            self.assertGreater(first_wait, 1.0)
            self.assertGreater(second_wait, first_wait + 1.0)

        self.run_asks(scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_asks_signal.py /path/to/masc_tui.exe")
    AsksSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
