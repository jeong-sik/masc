#!/usr/bin/env python3
"""The Planning screen reads its Goals again when the server announces a Goal
projection change, and the refresh cadence does not read them (RFC-0480).

The fixture answers both Planning reads with the smallest body each decoder
accepts, so a read never fails and is never retried.
"""

import os
import sys
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


PLANNING_PATH = "/api/v1/dashboard/planning"
GOALS_PATH = "/api/v1/dashboard/goals"
# Keepers is two Tabs from the opening Dashboard; Work (Planning) is one back.
TO_PLANNING = "\x1b[Z"

PLANNING_BODY: dict[str, object] = {
    "goals": [],
    "rollup": {
        "active_count": 0,
        "verifying_count": 0,
        "awaiting_confirmation_count": 0,
        "done_count": 0,
        "dropped_count": 0,
        "paused_count": 0,
        "blocked_count": 0,
    },
    "task_backlog": {
        "todo": 0,
        "claimed": 0,
        "in_progress": 0,
        "awaiting_verification": 0,
        "done": 0,
        "cancelled": 0,
    },
    "goal_history": {"unlisted": []},
    "generated_at": "2026-11-04T00:00:00Z",
}

GOALS_BODY: dict[str, object] = {"tree": []}


class PlanningHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(owed.ChatServer, self.server)
        path = urllib.parse.urlsplit(self.path).path
        if path in (PLANNING_PATH, GOALS_PATH):
            phase = server.record(path)
            body = PLANNING_BODY if path == PLANNING_PATH else GOALS_BODY
            if self.respond(200, body, workspace_receipt=True):
                server.responded(phase, path)
        else:
            super().do_GET()


class PlanningServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = PlanningHandler


def goal_projection_changed() -> dict[str, object]:
    return {"type": "goal_projection_changed", "ts_unix": 1.0}


def repositories_changed() -> dict[str, object]:
    return {"type": "repositories_changed", "ts_unix": 1.0}


class PlanningGoalSignalTest(unittest.TestCase):
    binary = ""

    def run_planning(
        self,
        scenario: Callable[[owed.ChatServer, Callable[..., None]], None],
        refresh_seconds: float = 1000.0,
    ) -> None:
        owed.ChatServer = PlanningServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def opened(server: owed.ChatServer, step: Callable[..., None]) -> None:
            server.set_phase("open")
            step("keys", TO_PLANNING)
            step(
                "wait",
                lambda: server.response_count("open", PLANNING_PATH) >= 1
                and server.response_count("open", GOALS_PATH) >= 1,
                "Planning did not read its Goals",
            )
            step("drain", 1.0)
            scenario(server, step)

        owed.ChatOwedHistoryTest.run_chat(
            cast(owed.ChatOwedHistoryTest, self), opened, refresh_seconds=refresh_seconds
        )

    def test_a_goal_projection_change_is_read(self) -> None:
        def scenario(server: owed.ChatServer, step: Callable[..., None]) -> None:
            server.set_phase("other")
            server.events.put(repositories_changed())
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 1,
                "the unrelated change was not sent",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("other", PLANNING_PATH), 0)
            self.assertEqual(server.count("other", GOALS_PATH), 0)
            server.set_phase("changed")
            server.events.put(goal_projection_changed())
            step(
                "wait",
                lambda: server.response_count("changed", PLANNING_PATH) == 1
                and server.response_count("changed", GOALS_PATH) == 1,
                "the Goal change did not read Planning",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("changed", PLANNING_PATH), 1)
            self.assertEqual(server.count("changed", GOALS_PATH), 1)

        self.run_planning(scenario)

    def test_the_cadence_does_not_read_planning(self) -> None:
        def scenario(server: owed.ChatServer, step: Callable[..., None]) -> None:
            server.set_phase("cadence")
            step("drain", 3.5)
            self.assertGreaterEqual(
                server.count("cadence", "/health"), 2, "the cadence did not run"
            )
            self.assertEqual(server.count("cadence", PLANNING_PATH), 0)
            self.assertEqual(server.count("cadence", GOALS_PATH), 0)

        self.run_planning(scenario, refresh_seconds=1.0)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_planning_goal_signal.py /path/to/masc_tui.exe")
    PlanningGoalSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
