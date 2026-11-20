#!/usr/bin/env python3
"""A Keeper's memory health push reads that Keeper's row, not the fleet, while
the Memory surface is on screen (RFC-0487).

The TUI has no refresh cadence (#48677), so every read after the surface opens
comes from a push or from arriving on the surface; one test waits through a
quiet stretch and sees it read nothing. The row read answers no
row, the answer for a Keeper the fleet does not list, so merging it changes
nothing and owes no fleet read. One test serves a fleet that lists the Keeper,
so its row merges and the input pane reads the Keeper's turn records.
"""

import os
import sys
import unittest
import urllib.parse
from typing import Callable, TypeAlias, cast

import test_tui_chat_owed_history as owed
import tui_memory_health_rows as rows


HEALTH_PATH = "/api/v1/dashboard/keeper-memory-health"
KEEPER = "fixture-keeper"
ROW_READ = HEALTH_PATH + "?keeper=" + KEEPER
INPUT_PATH = "/api/v1/keepers/" + KEEPER + "/turn-records"
# Ctrl-^ shows and hides the Browser lane.
TOGGLE_BROWSER_LANE = "\x1e"

# The fixture's server class, kept before [run_memory] points the fixture at
# [HealthServer].
BaseChatServer: TypeAlias = owed.ChatServer

# An empty fleet the TUI decodes: every total is zero because there is no row.
EMPTY_FLEET: dict[str, object] = rows.fleet([], execution={}, totals={})
# The Keeper's row with nothing in it and no alert: the fleet that lists it
# keeps every total and alert count at zero.
EMPTY_ROW: dict[str, object] = rows.keeper_row(KEEPER)
LISTED_FLEET: dict[str, object] = rows.fleet([EMPTY_ROW], execution={}, totals={})
# The input pane's answer for the Keeper: no turn record yet.
EMPTY_INPUT: dict[str, object] = {"keeper": KEEPER, "skipped_rows": 0, "entries": []}


class HealthHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(HealthServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == HEALTH_PATH:
            keeper = urllib.parse.parse_qs(request.query).get("keeper")
            if keeper is None:
                phase = server.record(HEALTH_PATH)
                if self.respond(200, server.fleet, workspace_receipt=True):
                    server.responded(phase, HEALTH_PATH)
            else:
                key = HEALTH_PATH + "?keeper=" + keeper[0]
                phase = server.record(key)
                body = {
                    "schema": rows.SCHEMA,
                    "generated_at": 2.0,
                    "keeper": server.row,
                }
                if self.respond(200, body, workspace_receipt=True):
                    server.responded(phase, key)
        elif request.path == INPUT_PATH:
            phase = server.record(INPUT_PATH)
            with server.condition:
                fail = server.input_failures_left > 0
                if fail:
                    server.input_failures_left -= 1
            if fail:
                sent = self.respond(503, {"error": "turn records unavailable"})
            else:
                sent = self.respond(200, EMPTY_INPUT, workspace_receipt=True)
            if sent:
                server.responded(phase, INPUT_PATH)
        else:
            super().do_GET()


class HealthServer(BaseChatServer):
    fleet: dict[str, object] = EMPTY_FLEET
    row: dict[str, object] | None = None

    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = HealthHandler
        self.input_failures_left = 0


class ListedHealthServer(HealthServer):
    fleet = LISTED_FLEET
    row = EMPTY_ROW


def dataset_changed(dataset: str, **subject: str) -> dict[str, object]:
    return {"type": "workspace_dataset_changed", "dataset": dataset, **subject}


class MemoryHealthSignalTest(unittest.TestCase):
    binary = ""

    def run_memory(
        self,
        scenario: Callable[[HealthServer, Callable[..., None]], None],
        refresh_seconds: float = 1000.0,
        server_class: type[HealthServer] = HealthServer,
    ) -> None:
        owed.ChatServer = server_class
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

        owed.ChatOwedHistoryTest.run_chat(
            cast(owed.ChatOwedHistoryTest, self), opened, refresh_seconds=refresh_seconds
        )

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

    def test_a_quiet_stretch_does_not_read_memory_health(self) -> None:
        def scenario(server: HealthServer, step: Callable[..., None]) -> None:
            server.set_phase("quiet")
            step("drain", 3.5)
            self.assertEqual(server.count("quiet", HEALTH_PATH), 0)
            self.assertEqual(server.count("quiet", ROW_READ), 0)

        self.run_memory(scenario)

    def test_a_failed_input_read_is_read_again_until_it_succeeds(self) -> None:
        def scenario(server: HealthServer, step: Callable[..., None]) -> None:
            step(
                "wait",
                lambda: server.response_count("open", INPUT_PATH) >= 1,
                "the input pane did not read the selected Keeper",
            )
            step("drain", 1.0)
            server.set_phase("failing")
            with server.condition:
                server.input_failures_left = 1
            server.events.put(dataset_changed("memory_health", keeper=KEEPER))
            step(
                "wait",
                lambda: server.response_count("failing", INPUT_PATH) >= 1,
                "the Keeper's merged row did not read the input pane",
            )
            server.set_phase("retry")
            # Nothing else is pushed: only the failed read can read it again.
            step(
                "wait",
                lambda: server.response_count("retry", INPUT_PATH) >= 1,
                "a failed input read was not read again",
            )
            # The read succeeded, so nothing is owed: a longer wait than the
            # next backoff reads nothing more.
            step("drain", 5.0)
            self.assertEqual(server.count("retry", INPUT_PATH), 1)
            self.assertEqual(server.count("retry", ROW_READ), 0)
            self.assertEqual(server.count("retry", HEALTH_PATH), 0)

        self.run_memory(scenario, server_class=ListedHealthServer)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_memory_health_signal.py /path/to/masc_tui.exe")
    MemoryHealthSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
