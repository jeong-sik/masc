#!/usr/bin/env python3
"""The held tool calls (Overview, Approvals) and the tool approval modes
(Keepers) read again when the server announces their change, and the held
calls again after a failed read (RFC-0480 L5).

The refresh cadence is pushed out of the test's lifetime, so every read after
a surface opens comes from an announcement or a failed read.
"""

import os
import sys
import time
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


HELD_PATH = "/api/v1/keepers/tool-approvals"
MODES_PATH = "/api/v1/keepers/tool-approval-mode"


class ApprovalsHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(ApprovalsServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == HELD_PATH:
            phase = server.record(request.path)
            with server.condition:
                server.held_times.append(time.monotonic())
                fail = server.held_failures_left > 0
                if fail:
                    server.held_failures_left -= 1
            if fail:
                sent = self.respond(503, {"error": "held calls unavailable"}, workspace_receipt=True)
            else:
                sent = self.respond(200, {"pending": []}, workspace_receipt=True)
            if sent:
                server.responded(phase, request.path)
        elif request.path == MODES_PATH:
            phase = server.record(request.path)
            if self.respond(200, {"overrides": []}, workspace_receipt=True):
                server.responded(phase, request.path)
        else:
            super().do_GET()


class ApprovalsServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = ApprovalsHandler
        self.held_times: list[float] = []
        self.held_failures_left = 0


def waits_changed() -> dict[str, object]:
    return {"type": "keeper_tool_approval_waits_changed", "name": "analyst"}


def mode_changed() -> dict[str, object]:
    return {"type": "keeper_tool_approval_mode_changed", "name": "analyst"}


class HeldCallsAndModesSignalTest(unittest.TestCase):
    binary = ""

    def run_surface(
        self,
        scenario: Callable[[ApprovalsServer, Callable[..., None]], None],
        *,
        to_overview: bool,
    ) -> None:
        owed.ChatServer = ApprovalsServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def opened(server: owed.ChatServer, step: Callable[..., None]) -> None:
            approvals = cast(ApprovalsServer, server)
            if to_overview:
                # Keepers -> Features & plugins -> Workspace -> System ->
                # Operations (#50465 took Usage and Board off the tab ring, so
                # Operations is four tabs from Keepers).
                approvals.set_phase("open")
                step("keys", "\t\t\t\t")
                step(
                    "wait",
                    lambda: approvals.response_count("open", HELD_PATH) >= 1,
                    "the Dashboard did not read the held calls",
                )
            step("drain", 1.0)
            scenario(approvals, step)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), opened)

    def test_a_mode_change_reads_the_modes_on_keepers(self) -> None:
        def scenario(server: ApprovalsServer, step: Callable[..., None]) -> None:
            server.set_phase("other")
            server.events.put(waits_changed())
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 1,
                "the held call change was not sent",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("other", MODES_PATH), 0)
            server.set_phase("changed")
            server.events.put(mode_changed())
            step(
                "wait",
                lambda: server.response_count("changed", MODES_PATH) == 1,
                "a mode change did not read the modes",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("changed", MODES_PATH), 1)

        self.run_surface(scenario, to_overview=False)

    def test_a_held_call_change_reads_the_held_calls_on_the_dashboard(self) -> None:
        def scenario(server: ApprovalsServer, step: Callable[..., None]) -> None:
            server.set_phase("other")
            server.events.put(mode_changed())
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 1,
                "the mode change was not sent",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("other", HELD_PATH), 0)
            server.set_phase("changed")
            server.events.put(waits_changed())
            step(
                "wait",
                lambda: server.response_count("changed", HELD_PATH) == 1,
                "a held call change did not read the held calls",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("changed", HELD_PATH), 1)

        self.run_surface(scenario, to_overview=True)

    def test_failed_held_call_reads_are_read_again_with_growing_waits(self) -> None:
        def scenario(server: ApprovalsServer, step: Callable[..., None]) -> None:
            with server.condition:
                server.held_failures_left = 2
                server.held_times.clear()
            server.events.put(waits_changed())
            step(
                "wait",
                lambda: len(server.held_times) >= 3,
                "two failed held call reads were not followed by a third",
            )
            step("drain", 6.0)
            with server.condition:
                times = list(server.held_times)
            # The third read succeeded, so nothing reads again.
            self.assertEqual(len(times), 3)
            first_wait = times[1] - times[0]
            second_wait = times[2] - times[1]
            self.assertGreater(first_wait, 1.0)
            self.assertGreater(second_wait, first_wait + 1.0)

        self.run_surface(scenario, to_overview=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_held_calls_and_modes_signal.py /path/to/masc_tui.exe")
    HeldCallsAndModesSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
