#!/usr/bin/env python3
"""An open async request detail reads again when its Keeper's async
requests change -- a request record or one of its execution journals was
written -- and again after a failed read. A change for another Keeper does
not read it (RFC-0480 §3.4).

The refresh cadence is pushed out of the test's lifetime, so every detail
read after the detail opens comes from an announcement or a failed read.
"""

import os
import sys
import time
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


ASYNC_PATH = "/api/v1/async-requests"
STATUS_PATH = "/api/v1/async-requests/status"

OBSERVATION: dict[str, object] = {
    "schema": "masc.async-request-observation/v1",
    "status": "ready",
    "summary": {"active": 1, "runtime_owned": 1, "ownership_unknown": 0, "record_errors": 0},
    "requests": [
        {
            "request_id": "req-detail-0001",
            "submitted_by": "detail-owner",
            "keeper_name": "analyst",
            "status": "running",
            "worker_ownership": "runtime_owned",
            "submitted_at": 1000.0,
            "elapsed_sec": 12.5,
        }
    ],
    "record_errors": [],
    "startup_recovery": None,
}

ABSENT: dict[str, object] = {"schema": "masc.async-request-status/v1", "status": "absent"}


class DetailHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(DetailServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == ASYNC_PATH:
            phase = server.record(request.path)
            if self.respond(200, OBSERVATION, workspace_receipt=True):
                server.responded(phase, request.path)
        elif request.path == STATUS_PATH:
            phase = server.record(request.path)
            with server.condition:
                server.status_times.append(time.monotonic())
                fail = server.status_failures_left > 0
                if fail:
                    server.status_failures_left -= 1
            if fail:
                sent = self.respond(503, {"error": "status unavailable"}, workspace_receipt=True)
            else:
                sent = self.respond(200, ABSENT, workspace_receipt=True)
            if sent:
                server.responded(phase, request.path)
        else:
            super().do_GET()


class DetailServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = DetailHandler
        self.status_times: list[float] = []
        self.status_failures_left = 0


def async_requests_changed(keeper: str) -> dict[str, object]:
    return {"type": "keeper_async_requests_changed", "name": keeper}


class AsyncDetailSignalTest(unittest.TestCase):
    binary = ""

    def run_detail(self, scenario: Callable[[DetailServer, Callable[..., None]], None]) -> None:
        owed.ChatServer = DetailServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def opened(server: owed.ChatServer, step: Callable[..., None]) -> None:
            detail = cast(DetailServer, server)
            detail.set_phase("tools")
            step("keys", ":")
            step("drain", 0.3)
            step("keys", "go Tools")
            step("drain", 0.3)
            step("keys", "\r")
            step(
                "wait",
                lambda: detail.response_count("tools", ASYNC_PATH) >= 1,
                "the Tools surface did not read the async requests",
            )
            step("drain", 0.5)
            # [p] moves from the Keeper surface to the async requests, [J]
            # selects the only one and Enter opens its detail.
            step("keys", "p")
            step("drain", 0.3)
            step("keys", "J")
            step("drain", 0.3)
            detail.set_phase("open")
            step("keys", "\r")
            step(
                "wait",
                lambda: detail.response_count("open", STATUS_PATH) >= 1,
                "opening the detail did not read it",
            )
            step("drain", 1.0)
            scenario(detail, step)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), opened)

    def test_its_keepers_change_reads_the_open_detail(self) -> None:
        def scenario(server: DetailServer, step: Callable[..., None]) -> None:
            server.set_phase("other")
            server.events.put(async_requests_changed("bravo"))
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 1,
                "the other Keeper's change was not sent",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("other", STATUS_PATH), 0)
            server.set_phase("changed")
            server.events.put(async_requests_changed("analyst"))
            step(
                "wait",
                lambda: server.response_count("changed", STATUS_PATH) == 1,
                "the Keeper's change did not read the open detail",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("changed", STATUS_PATH), 1)

        self.run_detail(scenario)

    def test_a_change_while_away_reads_the_detail_on_return(self) -> None:
        # The palette's Keeper chat leaves Tools with the detail still open.
        def scenario(server: DetailServer, step: Callable[..., None]) -> None:
            step("keys", ":")
            step("drain", 0.3)
            step("keys", "keeper analyst")
            step("drain", 0.3)
            step("keys", "\r")
            step("drain", 1.0)
            server.set_phase("away")
            server.events.put(async_requests_changed("analyst"))
            step(
                "wait",
                lambda: server.count("away", "observer-event-written") == 1,
                "the change was not sent",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("away", STATUS_PATH), 0)
            server.set_phase("back")
            step("keys", ":")
            step("drain", 0.3)
            step("keys", "go Tools")
            step("drain", 0.3)
            step("keys", "\r")
            step(
                "wait",
                lambda: server.response_count("back", STATUS_PATH) == 1,
                "returning to Tools did not read the detail the change owed",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("back", STATUS_PATH), 1)

        self.run_detail(scenario)

    def test_failed_detail_reads_are_read_again_with_growing_waits(self) -> None:
        def scenario(server: DetailServer, step: Callable[..., None]) -> None:
            with server.condition:
                server.status_failures_left = 2
                server.status_times.clear()
            server.events.put(async_requests_changed("analyst"))
            step(
                "wait",
                lambda: len(server.status_times) >= 3,
                "two failed reads were not followed by a third",
            )
            step("drain", 6.0)
            with server.condition:
                times = list(server.status_times)
            # The third read succeeded, so nothing reads again.
            self.assertEqual(len(times), 3)
            first_wait = times[1] - times[0]
            second_wait = times[2] - times[1]
            self.assertGreater(first_wait, 1.0)
            self.assertGreater(second_wait, first_wait + 1.0)

        self.run_detail(scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_async_detail_signal.py /path/to/masc_tui.exe")
    AsyncDetailSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
