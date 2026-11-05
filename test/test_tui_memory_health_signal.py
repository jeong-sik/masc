#!/usr/bin/env python3
"""A Keeper's memory health push reads the health once while a surface that
draws it is on screen (RFC-0480 §3.4).

The Usage surface draws the fleet's memory health. After arrival only a push
names the health, so every later read is counted against the pushes sent.
"""

import os
import sys
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


HEALTH_PATH = "/api/v1/dashboard/keeper-memory-health"

# The fixture's server class, kept before [run_usage] points the fixture at
# [HealthServer].
BaseChatServer = owed.ChatServer

# An empty fleet the TUI decodes: every total is zero because there is no row.
EMPTY_FLEET: dict[str, object] = {
    "schema": "keeper.memory_os.current_health.v8",
    "generated_at": 1.0,
    "execution": {},
    "keepers": [],
    "totals": {
        name: 0
        for name in (
            "facts",
            "observed_facts",
            "derived_facts",
            "support_invalidations",
            "snapshot_bytes",
            "added",
            "removed",
            "source_facts",
            "source_invalidations",
            "source_snapshot_bytes",
            "librarian_unread_turns",
            "librarian_continuity_unread_atoms",
            "librarian_continuity_unmeasured",
            "librarian_failures",
            "vision_ingest_errors",
            "read_errors",
            "source_read_errors",
        )
    },
    "alert_summary": {
        name: 0
        for name in (
            "total_alerts",
            "warn_alerts",
            "error_alerts",
            "keepers_with_alerts",
            "snapshot_read_error_keepers",
            "source_snapshot_read_error_keepers",
            "librarian_stopped_keepers",
            "librarian_starving_keepers",
        )
    },
}


class HealthHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(HealthServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == HEALTH_PATH:
            phase = server.record(request.path)
            if self.respond(200, EMPTY_FLEET):
                server.responded(phase, request.path)
        else:
            super().do_GET()


class HealthServer(BaseChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = HealthHandler


def dataset_changed(dataset: str, **subject: str) -> dict[str, object]:
    return {"type": "workspace_dataset_changed", "dataset": dataset, **subject}


class MemoryHealthSignalTest(unittest.TestCase):
    binary = ""

    def run_usage(self, scenario: Callable[[HealthServer, Callable[..., None]], None]) -> None:
        owed.ChatServer = HealthServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def opened(server: BaseChatServer, step: Callable[..., None]) -> None:
            health = cast(HealthServer, server)
            health.set_phase("open")
            # Keepers -> Usage.
            step("keys", "\t")
            step(
                "wait",
                lambda: health.response_count("open", HEALTH_PATH) >= 1,
                "the Usage surface did not read the memory health",
            )
            step("drain", 1.0)
            scenario(health, step)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), opened)

    def test_a_memory_health_push_reads_the_health_once(self) -> None:
        def scenario(server: HealthServer, step: Callable[..., None]) -> None:
            server.set_phase("other")
            server.events.put(dataset_changed("repositories"))
            server.events.put(dataset_changed("lanes"))
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 2,
                "the other dataset pushes were not sent",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("other", HEALTH_PATH), 0)
            server.set_phase("changed")
            server.events.put(dataset_changed("memory_health", keeper="fixture-keeper"))
            step(
                "wait",
                lambda: server.response_count("changed", HEALTH_PATH) == 1,
                "a memory health push did not read the health",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("changed", HEALTH_PATH), 1)

        self.run_usage(scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_memory_health_signal.py /path/to/masc_tui.exe")
    MemoryHealthSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
