#!/usr/bin/env python3
"""Lane pushes read only the visible inventory and open Inspect."""

import os
import sys
import threading
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


LANES = "/api/v1/lanes"
ADDONS = "/api/v1/lane-addons"


def exact_lane(name: str) -> dict:
    return {
        "lane_id": name,
        "label": name,
        "purpose": name,
        "required": name in {"hitl_auto_judge", "board_attention"},
        "observation_only": True,
        "configured": True,
        "configuration_state": "ready",
        "admitted_slots": ["account.model"],
        "cli_slots": [],
        "declared_slots": ["account.model"],
        "declared_cli_slots": [],
        "dropped_slots": [],
        "admission_error": None,
        "status": "no_retained_observation",
        "retained_run_count": 0,
        "running_count": 0,
        "succeeded_count": 0,
        "failed_count": 0,
        "cancelled_count": 0,
        "last_started_at": None,
        "last_terminal_at": None,
        "last_outcome": None,
        "p50_elapsed_s": None,
        "selected_slots": [],
        "runs_without_slot": {"vendor_system_one": 0, "server_restarted": 0, "no_slot": 0},
        **({"jev": {"state": "off"}} if name == "board_attention" else {}),
    }


def lane_payload() -> dict:
    lanes = ["librarian", "hitl_auto_judge", "board_attention", "verifier", "browser_stagehand", "candle_appraiser"]
    return {
        "schema": "masc.lane-inventory/v1",
        "observed_at": 1.0,
        "rows": [],
        "exact_snapshot": {
            "schema": "masc.standalone_llm_lanes.v2",
            "generated_at": "2026-10-04T00:00:00Z",
            "observed_at_unix": 1.0,
            "observation_only": True,
            "exact_run_projection_count": 0,
            "exact_run_source_total": 0,
            "exact_run_projection_truncated": False,
            "lanes": [exact_lane(name) for name in lanes],
        },
        "package_read": {"directory": "/config", "complete": True, "owner_present": True, "issues": []},
    }


def addon_payload() -> dict:
    return {
        "instances": [{
            "instance_id": "quiz-1",
            "run_id": "quiz",
            "addon_id": "operator-quiz",
            "title": "Operator quiz",
            "revision": "0.1.0",
            "phase": {"kind": "attached"},
            "runtime_presence": "live",
            "observation_seq": 1,
            "rows_count": 0,
            "incarnation": "quiz-1",
            "action_schema": None,
            "configuration": {"id": "operator-quiz", "source_path": "/c/operator-quiz.toml", "revision": "r1"},
            "binding": {"sources": []},
            "package": {"outputs": {"quiz": {"lanes": ["quiz/sessions"]}}, "skills_directory": None},
        }],
        "rows": [],
        "coverage": [],
        "configuration": {"directory": "/c", "complete": True, "declarations": [], "issues": []},
    }


class LaneHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(LaneServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == LANES:
            phase = server.record(request.path)
            if server.hold_lanes.is_set():
                server.hold_lanes.clear()
                server.lanes_held.set()
                server.release_lanes.wait()
            with server.condition:
                fail = server.failures_left > 0
                server.failures_left = max(0, server.failures_left - 1)
            sent = self.respond(503 if fail else 200, lane_payload())
            if sent:
                server.responded(phase, request.path)
            return
        if request.path == ADDONS:
            phase = server.record(request.path)
            if self.respond(200, addon_payload()):
                server.responded(phase, request.path)
            return
        super().do_GET()


class LaneServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = LaneHandler
        self.hold_lanes = threading.Event()
        self.lanes_held = threading.Event()
        self.release_lanes = threading.Event()


def dataset(name: str, instance_id: str | None = None) -> dict[str, object]:
    event: dict[str, object] = {"type": "workspace_dataset_changed", "dataset": name}
    if instance_id is not None:
        event["instance_id"] = instance_id
    return event


class LaneInventoryPushTest(unittest.TestCase):
    binary = ""

    def test_visible_scoped_reads_and_recovery(self) -> None:
        owed.ChatServer = LaneServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def scenario(server: owed.ChatServer, step: Callable[..., None]) -> None:
            lane = cast(LaneServer, server)
            lane.set_phase("open")
            step("keys", "9")
            step("wait", lambda: lane.response_count("open", LANES) >= 1, "Lanes did not open")
            step("keys", ":addons\n")
            step("wait", lambda: lane.response_count("open", ADDONS) >= 1, "Add-ons did not open")
            step("keys", "\r")

            lane.set_phase("inspect")
            lane.events.put(dataset("lane_addons", "quiz-1"))
            step("wait", lambda: lane.response_count("inspect", ADDONS) == 1,
                 "the instance above Lanes was not reread")
            lane.events.put(dataset("lane_addons", "someone-else"))
            step("drain", 0.5)
            self.assertEqual(lane.response_count("inspect", ADDONS), 1)

            lane.set_phase("trailing")
            lane.hold_lanes.set()
            lane.events.put(dataset("lanes"))
            step("wait", lane.lanes_held.is_set, "the first Lane read did not start")
            lane.events.put(dataset("lanes"))
            lane.events.put(dataset("lanes"))
            step("drain", 0.3)
            lane.release_lanes.set()
            step("wait", lambda: lane.response_count("trailing", LANES) == 2,
                 "two pushes during a read did not produce one trailing read")
            step("drain", 0.5)
            self.assertEqual(lane.response_count("trailing", LANES), 2)

            lane.set_phase("retry")
            with lane.condition:
                lane.failures_left = 1
            lane.events.put(dataset("lanes"))
            step("wait", lambda: lane.response_count("retry", LANES) == 2,
                 "a failed Lane read was not retried")
            step("drain", 0.5)
            self.assertEqual(lane.response_count("retry", LANES), 2)

            lane.set_phase("hidden-addons")
            step("keys", "\x1b")
            lane.events.put(dataset("lane_addons", "quiz-1"))
            step("drain", 0.7)
            self.assertEqual(lane.response_count("hidden-addons", ADDONS), 0)

            lane.set_phase("hidden-lanes")
            step("keys", "\x1b\t")
            lane.events.put(dataset("lanes"))
            step("drain", 0.7)
            self.assertEqual(lane.response_count("hidden-lanes", LANES), 0)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_lane_inventory_push.py /path/to/masc_tui.exe")
    LaneInventoryPushTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
