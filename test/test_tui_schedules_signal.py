#!/usr/bin/env python3
"""The schedule list behind the agenda strip reads again when the server
announces that the schedules changed, and again after a failed read
(RFC-0480 L8).

The refresh cadence is pushed out of the test's lifetime, so every read
after the workspace is admitted comes from an announcement or a failed read.
One case runs the cadence every second and checks that it does not read
them.
"""

import os
import sys
import time
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


SCHEDULES_PATH = "/api/v1/dashboard/scheduled-automation"


class SchedulesHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(SchedulesServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == "/health":
            with server.condition:
                server.health_reads += 1
        if request.path == SCHEDULES_PATH:
            phase = server.record(request.path)
            with server.condition:
                server.read_times.append(time.monotonic())
                fail = server.failures_left > 0
                if fail:
                    server.failures_left -= 1
            # The TUI reads every 2xx through the workspace-bound reader, which
            # requires the admission receipt on the response itself. Without it
            # a 200 is a failed read ("Server did not attest the requested
            # workspace read"), so the third read of this test could never be
            # the success it asserts on. 503 stays receipt-free: the reader
            # passes non-2xx through and decodes the refusal instead.
            if fail:
                sent = self.respond(503, {"error": "schedule list unavailable"})
            else:
                sent = self.respond(
                    200,
                    {
                        "generated_at": "2026-11-03T00:00:00Z",
                        "status": "ok",
                        "request_count": 0,
                        "truncated": False,
                        "fsm": {"next_due_at": None},
                        "counts": None,
                        "requests": [],
                        "schedule_runner": {"status": "ok"},
                    },
                    workspace_receipt=True,
                )
            if sent:
                server.responded(phase, request.path)
        else:
            super().do_GET()


class SchedulesServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = SchedulesHandler
        self.read_times: list[float] = []
        self.failures_left = 0
        self.health_reads = 0


def schedule_store_invalidated() -> dict[str, object]:
    return {"type": "schedule_store_invalidated"}


def held_call_changed() -> dict[str, object]:
    return {"type": "keeper_tool_approval_waits_changed", "name": "analyst"}


class SchedulesSignalTest(unittest.TestCase):
    binary = ""

    def run_schedules(
        self,
        scenario: Callable[[SchedulesServer, Callable[..., None]], None],
        refresh_seconds: float = 1000.0,
    ) -> None:
        owed.ChatServer = SchedulesServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def admitted(server: owed.ChatServer, step: Callable[..., None]) -> None:
            schedules = cast(SchedulesServer, server)
            step("drain", 1.0)
            with schedules.condition:
                startup_reads = len(schedules.read_times)
            self.assertGreaterEqual(startup_reads, 1, "the agenda was not read at startup")
            scenario(schedules, step)

        owed.ChatOwedHistoryTest.run_chat(
            cast(owed.ChatOwedHistoryTest, self), admitted, refresh_seconds
        )

    def test_a_schedule_change_reads_the_schedules(self) -> None:
        def scenario(server: SchedulesServer, step: Callable[..., None]) -> None:
            server.set_phase("other")
            server.events.put(held_call_changed())
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 1,
                "the held call change was not sent",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("other", SCHEDULES_PATH), 0)
            server.set_phase("changed")
            server.events.put(schedule_store_invalidated())
            step(
                "wait",
                lambda: server.response_count("changed", SCHEDULES_PATH) == 1,
                "a schedule change did not read the schedules",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("changed", SCHEDULES_PATH), 1)

        self.run_schedules(scenario)

    def test_the_cadence_does_not_read_the_schedules(self) -> None:
        def scenario(server: SchedulesServer, step: Callable[..., None]) -> None:
            server.set_phase("cadence")
            with server.condition:
                health_before = server.health_reads
            step("drain", 3.5)
            with server.condition:
                cadence_passes = server.health_reads - health_before
            self.assertGreaterEqual(cadence_passes, 2, "the cadence did not run")
            self.assertEqual(server.count("cadence", SCHEDULES_PATH), 0)

        self.run_schedules(scenario, refresh_seconds=1.0)

    def test_failed_schedule_reads_are_read_again_with_growing_waits(self) -> None:
        def scenario(server: SchedulesServer, step: Callable[..., None]) -> None:
            with server.condition:
                server.failures_left = 2
                server.read_times.clear()
            server.events.put(schedule_store_invalidated())
            step(
                "wait",
                lambda: len(server.read_times) >= 3,
                "two failed reads were not followed by a third",
            )
            step("drain", 6.0)
            with server.condition:
                times = list(server.read_times)
            # The third read succeeded, so nothing reads again.
            self.assertEqual(len(times), 3)
            first_wait = times[1] - times[0]
            second_wait = times[2] - times[1]
            self.assertGreater(first_wait, 1.0)
            self.assertGreater(second_wait, first_wait + 1.0)

        self.run_schedules(scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_schedules_signal.py /path/to/masc_tui.exe")
    SchedulesSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
