#!/usr/bin/env python3
"""The Gate snapshot reads again when the server announces a Gate change, and
again after a failed read (RFC-0480 L5).

The refresh cadence is pushed out of the test's lifetime, so every Gate read
after the workspace is admitted comes from an announcement, a failed read or
an operator's refresh.
"""

import os
import sys
import time
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


GATE_PATH = "/api/v1/dashboard/gate"


class GateHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(GateServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == GATE_PATH:
            phase = server.record(request.path)
            with server.condition:
                server.gate_times.append(time.monotonic())
                fail = server.gate_failures_left > 0
                if fail:
                    server.gate_failures_left -= 1
            if fail:
                sent = self.respond(503, {"error": "gate unavailable"}, workspace_receipt=True)
            else:
                sent = self.respond(200, {"approval_queue": []}, workspace_receipt=True)
            if sent:
                server.responded(phase, request.path)
        else:
            super().do_GET()


class GateServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = GateHandler
        self.gate_times: list[float] = []
        self.gate_failures_left = 0


def approval_resolved() -> dict[str, object]:
    return {
        "type": "approval:resolved",
        "payload": {
            "id": "approval-1",
            "keeper_name": "analyst",
            "tool_name": "Execute",
            "decision": "approve",
        },
    }


def held_call_changed() -> dict[str, object]:
    return {"type": "keeper_tool_approval_waits_changed", "name": "analyst"}


class GateSnapshotSignalTest(unittest.TestCase):
    binary = ""

    def run_gate(self, scenario: Callable[[GateServer, Callable[..., None]], None]) -> None:
        owed.ChatServer = GateServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def admitted(server: owed.ChatServer, step: Callable[..., None]) -> None:
            gate = cast(GateServer, server)
            self.assertGreaterEqual(
                gate.response_count("setup", GATE_PATH), 1, "the admitted workspace read no Gate"
            )
            scenario(gate, step)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), admitted)

    def test_a_gate_change_reads_the_snapshot(self) -> None:
        def scenario(server: GateServer, step: Callable[..., None]) -> None:
            server.set_phase("other")
            server.events.put(held_call_changed())
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 1,
                "the held call change was not sent",
            )
            step("drain", 2.0)
            self.assertEqual(server.count("other", GATE_PATH), 0)
            server.set_phase("changed")
            server.events.put(approval_resolved())
            step(
                "wait",
                lambda: server.response_count("changed", GATE_PATH) == 1,
                "a Gate change did not read the snapshot",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("changed", GATE_PATH), 1)

        self.run_gate(scenario)

    def test_failed_gate_reads_are_read_again_with_growing_waits(self) -> None:
        def scenario(server: GateServer, step: Callable[..., None]) -> None:
            step("drain", 1.0)
            with server.condition:
                server.gate_failures_left = 2
                server.gate_times.clear()
            server.events.put(approval_resolved())
            step(
                "wait",
                lambda: len(server.gate_times) >= 3,
                "two failed Gate reads were not followed by a third",
            )
            step("drain", 6.0)
            with server.condition:
                times = list(server.gate_times)
            # The third read succeeded, so nothing reads again.
            self.assertEqual(len(times), 3)
            first_wait = times[1] - times[0]
            second_wait = times[2] - times[1]
            self.assertGreater(first_wait, 1.0)
            self.assertGreater(second_wait, first_wait + 1.0)

        self.run_gate(scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_gate_snapshot_signal.py /path/to/masc_tui.exe")
    GateSnapshotSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
