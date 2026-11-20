#!/usr/bin/env python3
"""The visible Memory health reads follow changes, never a shared cadence."""

import os
import sys
import threading
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed
import tui_memory_health_rows as rows


HEALTH_PATH = "/api/v1/dashboard/keeper-memory-health"
def health_payload() -> dict[str, object]:
    keeper = rows.keeper_row(
        "alpha",
        revision=1,
        updated_at=1.0,
        facts=1,
        observed_facts=1,
        snapshot_bytes=16,
        added=1,
        snapshot_present=True,
        age_bins=[1] + [0] * 23,
        facts_by_hour=[{"recorded_at": 1.0, "facts": 1}],
    )
    return rows.fleet(
        [keeper],
        execution={
            "schema": "keeper.memory_execution_availability.v1",
            "status": "disabled",
            "operator_action_required": False,
            "status_reasons": [],
            "operator_action_reasons": [],
            "operations": [],
            "semantics": "Configuration and last-cycle observation only; no provider success, source consumption or Memory commit is implied",
        },
        totals={"facts": 1, "observed_facts": 1, "snapshot_bytes": 16, "added": 1},
    )


def memory_dataset(keeper: str = "alpha") -> dict[str, object]:
    return {"type": "workspace_dataset_changed", "dataset": "memory_health", "keeper": keeper}


class MemoryHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(MemoryServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == HEALTH_PATH:
            phase = server.record("health")
            if server.hold_health.is_set():
                server.hold_health.clear()
                server.health_held.set()
                server.release_health.wait()
            with server.condition:
                fail = server.failures_left > 0
                server.failures_left = max(0, server.failures_left - 1)
            sent = self.respond(503 if fail else 200, health_payload())
            if sent:
                server.responded(phase, "health")
            return
        super().do_GET()


class MemoryServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = MemoryHandler
        self.hold_health = threading.Event()
        self.health_held = threading.Event()
        self.release_health = threading.Event()


class MemoryPushTest(unittest.TestCase):
    binary = ""

    def test_visible_reads_trailing_retry_and_reconnect(self) -> None:
        owed.ChatServer = MemoryServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def scenario(server: owed.ChatServer, step: Callable[..., None]) -> None:
            memory = cast(MemoryServer, server)
            memory.set_phase("open")
            step("keys", ":go Memory")
            step("drain", 0.3)
            step("keys", "\r")
            step("wait", lambda: memory.response_count("open", "health") == 1,
                 "Memory did not complete its initial health read")
            step("drain", 2.4)
            self.assertEqual(memory.response_count("open", "health"), 1,
                             "Memory kept reading while idle")

            memory.set_phase("unrelated")
            memory.events.put({"type": "workspace_dataset_changed", "dataset": "lanes"})
            step("drain", 0.5)
            self.assertEqual(memory.count("unrelated", "health"), 0)

            memory.set_phase("changed")
            memory.events.put(memory_dataset())
            step("wait", lambda: memory.response_count("changed", "health") == 1,
                 "a Memory change did not read exactly once")

            memory.set_phase("trailing")
            memory.hold_health.set()
            memory.events.put(memory_dataset())
            step("wait", memory.health_held.is_set, "the first Memory change read did not start")
            memory.events.put(memory_dataset())
            memory.events.put(memory_dataset())
            step("drain", 0.3)
            memory.release_health.set()
            step("wait", lambda: memory.response_count("trailing", "health") == 2,
                 "a Memory burst did not produce one trailing read")
            step("drain", 0.5)
            self.assertEqual(memory.response_count("trailing", "health"), 2)

            memory.set_phase("retry")
            with memory.condition:
                memory.failures_left = 1
            memory.events.put(memory_dataset())
            step("wait", lambda: memory.response_count("retry", "health") == 2,
                 "a failed Memory read was not retried")

            memory.set_phase("reconnect")
            memory.events.put("close")
            step("wait", lambda: memory.response_count("reconnect", "health") >= 1,
                 "observer replacement did not revalidate Memory")

            memory.set_phase("leaving")
            step("keys", "\x1b")
            step("drain", 0.5)
            memory.set_phase("hidden")
            memory.events.put(memory_dataset())
            step("drain", 0.5)
            self.assertEqual(memory.count("hidden", "health"), 0,
                             "a hidden Memory surface still read after a notification")

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_memory_push.py /path/to/masc_tui.exe")
    MemoryPushTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
