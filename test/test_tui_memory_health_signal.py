#!/usr/bin/env python3
"""A Keeper's memory health push reads that Keeper's row, not the fleet, while
the Memory surface is on screen (RFC-0487).

The refresh cadence is pushed out of the test's lifetime, so every read after
the surface opens comes from a push or from arriving on the surface. The row
read answers no row, the answer for a Keeper the fleet does not list, so
merging it changes nothing and owes no fleet read.
"""

import os
import sys
import unittest
import urllib.parse
from typing import Callable, TypeAlias, cast

import test_tui_chat_owed_history as owed


HEALTH_PATH = "/api/v1/dashboard/keeper-memory-health"
KEEPER = "fixture-keeper"
ROW_READ = HEALTH_PATH + "?keeper=" + KEEPER
# Ctrl-^ shows and hides the Browser lane.
TOGGLE_BROWSER_LANE = "\x1e"

# The fixture's server class, kept before [run_memory] points the fixture at
# [HealthServer].
BaseChatServer: TypeAlias = owed.ChatServer

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
            keeper = urllib.parse.parse_qs(request.query).get("keeper")
            if keeper is None:
                phase = server.record(HEALTH_PATH)
                if self.respond(200, EMPTY_FLEET, workspace_receipt=True):
                    server.responded(phase, HEALTH_PATH)
            else:
                key = HEALTH_PATH + "?keeper=" + keeper[0]
                phase = server.record(key)
                body = {
                    "schema": "keeper.memory_os.current_health.v8",
                    "generated_at": 2.0,
                    "keeper": None,
                }
                if self.respond(200, body, workspace_receipt=True):
                    server.responded(phase, key)
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

    def run_memory(self, scenario: Callable[[HealthServer, Callable[..., None]], None]) -> None:
        owed.ChatServer = HealthServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def opened(server: owed.ChatServer, step: Callable[..., None]) -> None:
            health = cast(HealthServer, server)
            health.set_phase("open")
            step("keys", ":")
            step("drain", 0.3)
            step("keys", "go Memory")
            step("drain", 0.3)
            step("keys", "\r")
            step(
                "wait",
                lambda: health.response_count("open", HEALTH_PATH) >= 1,
                "the Memory surface did not read the memory health",
            )
            step("drain", 1.0)
            scenario(health, step)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), opened)

    def test_a_memory_health_push_reads_that_keepers_row(self) -> None:
        def scenario(server: HealthServer, step: Callable[..., None]) -> None:
            server.set_phase("other")
            server.events.put(dataset_changed("repositories"))
            server.events.put(dataset_changed("harness_verdicts"))
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 2,
                "the other dataset pushes were not sent",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("other", HEALTH_PATH), 0)
            self.assertEqual(server.count("other", ROW_READ), 0)
            server.set_phase("changed")
            server.events.put(dataset_changed("memory_health", keeper=KEEPER))
            step(
                "wait",
                lambda: server.response_count("changed", ROW_READ) == 1,
                "a memory health push did not read the Keeper's row",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("changed", ROW_READ), 1)
            self.assertEqual(server.count("changed", HEALTH_PATH), 0)

        self.run_memory(scenario)

    def test_leaving_the_browser_lane_reads_what_it_covered(self) -> None:
        def scenario(server: HealthServer, step: Callable[..., None]) -> None:
            server.set_phase("covered")
            step("keys", TOGGLE_BROWSER_LANE)
            step("drain", 1.0)
            server.events.put(dataset_changed("memory_health", keeper=KEEPER))
            step(
                "wait",
                lambda: server.count("covered", "observer-event-written") == 1,
                "the memory health push was not sent",
            )
            step("drain", 1.5)
            # Under the lane Memory is off screen: the push owes nothing.
            self.assertEqual(server.count("covered", ROW_READ), 0, "the lane did not cover Memory")
            self.assertEqual(server.count("covered", HEALTH_PATH), 0)
            server.set_phase("returned")
            step("keys", TOGGLE_BROWSER_LANE)
            step(
                "wait",
                lambda: server.response_count("returned", HEALTH_PATH) >= 1,
                "returning from the Browser lane did not read the memory health",
            )

        self.run_memory(scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_memory_health_signal.py /path/to/masc_tui.exe")
    MemoryHealthSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
