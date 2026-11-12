#!/usr/bin/env python3
"""The visible Memory health reads follow changes, never a shared cadence."""

import os
import sys
import threading
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


HEALTH_PATH = "/api/v1/dashboard/keeper-memory-health"
# Every pass and change the server counts, none moved since it started.
NO_MEMORY_CHANGES = {
    commit_pass: {change: 0 for change in ("added", "absorbed", "superseded", "dropped")}
    for commit_pass in (
        "admission", "durable", "continuity", "cleanup", "keeper_write", "keeper_delete", "operator_delete",
    )
}


def health_payload() -> dict:
    available = {"kind": "available", "messages": []}
    context_cycle = {
        "saved": None,
        "saved_read_error": None,
        "read_position": None,
        "read_position_read_error": None,
        "rewriting_through": None,
        "prepared": None,
        "synthesis": None,
        "unread": {"snapshot": available, "memory": available},
    }
    librarian = {
        "state": "drained",
        "detail": None,
        "pending": None,
        "admission_wait": None, "operator_action_required": False,
        "measured_at": 1.0,
        "unread_atom_turns": 0,
        "unread_official_turns": 0,
        "continuity_unread_atoms": 0,
        "last_success_at": None,
        "last_failure_kind": None,
        "stalled": None,
    }
    keeper = {
        "keeper_id": "alpha",
        "revision": 1,
        "updated_at": 1.0,
        "facts": 1,
        "observed_facts": 1,
        "derived_facts": 0,
        "support_invalidations": 0,
        "snapshot_bytes": 16,
        "added": 1,
        "removed": 0,
        "snapshot_present": True,
        "age_bins": [1] + [0] * 23,
        "facts_by_hour": [{"recorded_at": 1.0, "facts": 1}],
        "changes_since_start": NO_MEMORY_CHANGES,
        "context_cycle": context_cycle,
        "librarian": librarian,
        "librarian_failures": 0,
        "vision_ingest_errors": 0,
        "vision_ingest_error_reasons": [],
        "read_error": None,
        "source_revision": 0,
        "source_facts": 0,
        "source_invalidations": 0,
        "source_snapshot_bytes": 0,
        "source_snapshot_present": False,
        "source_read_error": None,
        "alerts": [],
    }
    return {
        "schema": "keeper.memory_os.current_health.v15",
        "generated_at": 1.0,
        "execution": {
            "schema": "keeper.memory_execution_availability.v1",
            "status": "disabled",
            "operator_action_required": False,
            "status_reasons": [],
            "operator_action_reasons": [],
            "operations": [],
            "semantics": "Configuration and last-cycle observation only; no provider success, source consumption or Memory commit is implied",
        },
        "keepers": [keeper],
        "totals": {
            "facts": 1,
            "observed_facts": 1,
            "derived_facts": 0,
            "support_invalidations": 0,
            "snapshot_bytes": 16,
            "added": 1,
            "removed": 0,
            "source_facts": 0,
            "source_invalidations": 0,
            "source_snapshot_bytes": 0,
            "librarian_unread_turns": 0,
            "librarian_continuity_unread_atoms": 0,
            "librarian_continuity_unmeasured": 0,
            "librarian_failures": 0,
            "vision_ingest_errors": 0,
            "read_errors": 0,
            "source_read_errors": 0,
        },
        "alert_summary": {
            "total_alerts": 0,
            "warn_alerts": 0,
            "error_alerts": 0,
            "keepers_with_alerts": 0,
            "snapshot_read_error_keepers": 0,
            "source_snapshot_read_error_keepers": 0,
            "librarian_stopped_keepers": 0, "librarian_attention_required_keepers": 0,
            "librarian_starving_keepers": 0,
        },
    }


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
