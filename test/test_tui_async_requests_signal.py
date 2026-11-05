#!/usr/bin/env python3
"""The durable async requests the Keepers list draws read again when the
server announces a change to them, and again after a failed read
(RFC-0480 L8).

The refresh cadence is pushed out of the test's lifetime, so every read
after the list opens comes from an announcement or a failed read.
"""

import os
import sys
import time
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


ASYNC_PATH = "/api/v1/async-requests"


class AsyncHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(AsyncServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == ASYNC_PATH:
            phase = server.record(request.path)
            with server.condition:
                server.async_times.append(time.monotonic())
                fail = server.async_failures_left > 0
                if fail:
                    server.async_failures_left -= 1
            if fail:
                sent = self.respond(503, {"error": "async inventory unavailable"}, workspace_receipt=True)
            else:
                sent = self.respond(
                    200,
                    {
                        "schema": "masc.async-request-observation/v1",
                        "status": "ready",
                        "summary": {
                            "active": 0,
                            "runtime_owned": 0,
                            "ownership_unknown": 0,
                            "record_errors": 0,
                        },
                        "requests": [],
                        "record_errors": [],
                        "startup_recovery": None,
                    },
                    workspace_receipt=True,
                )
            if sent:
                server.responded(phase, request.path)
        else:
            super().do_GET()


class AsyncServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = AsyncHandler
        self.async_times: list[float] = []
        self.async_failures_left = 0


def async_requests_changed() -> dict[str, object]:
    return {"type": "keeper_async_requests_changed", "name": "analyst"}


def held_call_changed() -> dict[str, object]:
    return {"type": "keeper_tool_approval_waits_changed", "name": "analyst"}


class AsyncRequestsSignalTest(unittest.TestCase):
    binary = ""

    def run_list(self, scenario: Callable[[AsyncServer, Callable[..., None]], None]) -> None:
        owed.ChatServer = AsyncServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def on_list(server: owed.ChatServer, step: Callable[..., None]) -> None:
            listing = cast(AsyncServer, server)
            step(
                "wait",
                lambda: listing.response_count("setup", ASYNC_PATH) >= 1,
                "the Keepers list did not read the async requests",
            )
            step("drain", 1.0)
            scenario(listing, step)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), on_list)

    def test_an_async_request_change_reads_the_list(self) -> None:
        def scenario(server: AsyncServer, step: Callable[..., None]) -> None:
            server.set_phase("other")
            server.events.put(held_call_changed())
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 1,
                "the held call change was not sent",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("other", ASYNC_PATH), 0)
            server.set_phase("changed")
            server.events.put(async_requests_changed())
            step(
                "wait",
                lambda: server.response_count("changed", ASYNC_PATH) == 1,
                "an async request change did not read the list",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("changed", ASYNC_PATH), 1)

        self.run_list(scenario)

    def test_failed_async_request_reads_are_read_again_with_growing_waits(self) -> None:
        def scenario(server: AsyncServer, step: Callable[..., None]) -> None:
            with server.condition:
                server.async_failures_left = 2
                server.async_times.clear()
            server.events.put(async_requests_changed())
            step(
                "wait",
                lambda: len(server.async_times) >= 3,
                "two failed reads were not followed by a third",
            )
            step("drain", 6.0)
            with server.condition:
                times = list(server.async_times)
            # The third read succeeded, so nothing reads again.
            self.assertEqual(len(times), 3)
            first_wait = times[1] - times[0]
            second_wait = times[2] - times[1]
            self.assertGreater(first_wait, 1.0)
            self.assertGreater(second_wait, first_wait + 1.0)

        self.run_list(scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_async_requests_signal.py /path/to/masc_tui.exe")
    AsyncRequestsSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
