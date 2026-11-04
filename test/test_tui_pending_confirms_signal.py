#!/usr/bin/env python3
"""The confirmations waiting for an operator read again when the server
announces a change to them or a passed deadline, and again after a failed
read (RFC-0480 L8).

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


OPERATOR_PATH = "/api/v1/operator"


class ConfirmsHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(ConfirmsServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == "/health":
            with server.condition:
                server.health_reads += 1
        if request.path == OPERATOR_PATH:
            phase = server.record(request.path)
            with server.condition:
                server.read_times.append(time.monotonic())
                fail = server.failures_left > 0
                if fail:
                    server.failures_left -= 1
            if fail:
                sent = self.respond(503, {"error": "operator summary unavailable"})
            else:
                sent = self.respond(
                    200,
                    {
                        "workspace_identity": {
                            "base_path": server.base,
                            "masc_root": server.base + "/.masc",
                            "state_ready": True,
                        },
                        "pending_confirm_envelope": {
                            "items": [],
                            "summary": {
                                "actor_filter": "dashboard",
                                "filter_active": True,
                                "visible_count": 0,
                                "total_count": 0,
                                "hidden_count": 0,
                                "hidden_actors": [],
                                "confirm_required_actions": [],
                            },
                        },
                    },
                    # The pending-confirmation read goes through the
                    # workspace-bound reader, which requires the admission
                    # receipt on the response itself; without it a 200 is a
                    # failed read and the retries replace the single answer
                    # this test counts. 503 above stays receipt-free.
                    workspace_receipt=True,
                )
            if sent:
                server.responded(phase, request.path)
        else:
            super().do_GET()


class ConfirmsServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = ConfirmsHandler
        self.read_times: list[float] = []
        self.failures_left = 0
        self.health_reads = 0


def pending_confirm_invalidated() -> dict[str, object]:
    return {"type": "operator_pending_confirm_invalidated"}


def held_call_changed() -> dict[str, object]:
    return {"type": "keeper_tool_approval_waits_changed", "name": "analyst"}


class PendingConfirmsSignalTest(unittest.TestCase):
    binary = ""

    def run_confirms(
        self,
        scenario: Callable[[ConfirmsServer, Callable[..., None]], None],
        refresh_seconds: float = 1000.0,
    ) -> None:
        owed.ChatServer = ConfirmsServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def admitted(server: owed.ChatServer, step: Callable[..., None]) -> None:
            confirms = cast(ConfirmsServer, server)
            step("drain", 1.0)
            scenario(confirms, step)

        owed.ChatOwedHistoryTest.run_chat(
            cast(owed.ChatOwedHistoryTest, self), admitted, refresh_seconds
        )

    def test_a_confirmation_change_reads_the_confirmations(self) -> None:
        def scenario(server: ConfirmsServer, step: Callable[..., None]) -> None:
            server.set_phase("other")
            server.events.put(held_call_changed())
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 1,
                "the held call change was not sent",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("other", OPERATOR_PATH), 0)
            server.set_phase("changed")
            server.events.put(pending_confirm_invalidated())
            step(
                "wait",
                lambda: server.response_count("changed", OPERATOR_PATH) == 1,
                "a confirmation change did not read the confirmations",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("changed", OPERATOR_PATH), 1)

        self.run_confirms(scenario)

    def test_the_cadence_does_not_read_the_confirmations(self) -> None:
        def scenario(server: ConfirmsServer, step: Callable[..., None]) -> None:
            server.set_phase("cadence")
            with server.condition:
                health_before = server.health_reads
            step("drain", 3.5)
            with server.condition:
                cadence_passes = server.health_reads - health_before
            self.assertGreaterEqual(cadence_passes, 2, "the cadence did not run")
            self.assertEqual(server.count("cadence", OPERATOR_PATH), 0)

        self.run_confirms(scenario, refresh_seconds=1.0)

    def test_failed_confirmation_reads_are_read_again_with_growing_waits(self) -> None:
        def scenario(server: ConfirmsServer, step: Callable[..., None]) -> None:
            with server.condition:
                server.failures_left = 2
                server.read_times.clear()
            server.events.put(pending_confirm_invalidated())
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

        self.run_confirms(scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_pending_confirms_signal.py /path/to/masc_tui.exe")
    PendingConfirmsSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
