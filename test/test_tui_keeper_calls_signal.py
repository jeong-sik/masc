#!/usr/bin/env python3
"""The Keeper_calls surface reads its Keeper's tool calls again when the
server announces a tool call of that Keeper, and again after a failed read
(RFC-0480 L3).

The TUI reads nothing on a clock, so every calls read
after the surface opens comes from an announcement or a failed read.
"""

import os
import sys
import time
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


CALLS_PATH = "/api/v1/keepers/analyst/tool-calls"


def calls_body() -> dict[str, object]:
    return {"keeper": "analyst", "health": "ok", "entries": []}


class CallsHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(CallsServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == CALLS_PATH:
            phase = server.record(request.path)
            with server.condition:
                server.calls_times.append(time.monotonic())
                fail = server.calls_failures_left > 0
                if fail:
                    server.calls_failures_left -= 1
            if fail:
                sent = self.respond(503, {"error": "tool calls unavailable"}, workspace_receipt=True)
            else:
                sent = self.respond(200, calls_body(), workspace_receipt=True)
            if sent:
                server.responded(phase, request.path)
        else:
            super().do_GET()


class CallsServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = CallsHandler
        self.calls_times: list[float] = []
        self.calls_failures_left = 0


def tool_called(keeper: str) -> dict[str, object]:
    return {
        "type": "keeper_tool_call",
        "name": keeper,
        "tool_name": "tool_execute",
        "duration_ms": 10,
        "disposition": "completed",
        "ts_unix": 1.0,
        "turn": 1,
    }


class KeeperCallsSignalTest(unittest.TestCase):
    binary = ""

    def run_calls(self, scenario: Callable[[CallsServer, Callable[..., None]], None]) -> None:
        owed.ChatServer = CallsServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def opened(server: owed.ChatServer, step: Callable[..., None]) -> None:
            calls = cast(CallsServer, server)
            calls.set_phase("open")
            step("keys", "t")
            step(
                "wait",
                lambda: calls.response_count("open", CALLS_PATH) >= 1,
                "the calls surface did not read its Keeper's tool calls",
            )
            step("drain", 1.0)
            scenario(calls, step)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), opened)

    def test_a_tool_call_of_the_surface_keeper_is_read(self) -> None:
        def scenario(server: CallsServer, step: Callable[..., None]) -> None:
            server.set_phase("other")
            server.events.put(tool_called("someone-else"))
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 1,
                "the other Keeper's tool call was not sent",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("other", CALLS_PATH), 0)
            server.set_phase("changed")
            server.events.put(tool_called("analyst"))
            step(
                "wait",
                lambda: server.response_count("changed", CALLS_PATH) == 1,
                "the surface Keeper's tool call did not cause a calls read",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("changed", CALLS_PATH), 1)

        self.run_calls(scenario)

    def test_failed_calls_reads_are_read_again_with_growing_waits(self) -> None:
        def scenario(server: CallsServer, step: Callable[..., None]) -> None:
            with server.condition:
                server.calls_failures_left = 2
                server.calls_times.clear()
            server.events.put(tool_called("analyst"))
            step(
                "wait",
                lambda: len(server.calls_times) >= 3,
                "two failed calls reads were not followed by a third",
            )
            step("drain", 6.0)
            with server.condition:
                times = list(server.calls_times)
            # The third read succeeded, so nothing reads again.
            self.assertEqual(len(times), 3)
            first_wait = times[1] - times[0]
            second_wait = times[2] - times[1]
            self.assertGreater(first_wait, 1.0)
            self.assertGreater(second_wait, first_wait + 1.0)

        self.run_calls(scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_keeper_calls_signal.py /path/to/masc_tui.exe")
    KeeperCallsSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
