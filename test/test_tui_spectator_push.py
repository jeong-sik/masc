#!/usr/bin/env python3
"""Machine spectators read only visible changes and control the ticker by SSE."""

import os
import sys
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed
import test_tui_lane_inventory_push as lane_fixture


LIVE_PATH = "/api/v1/lane-addons/live"


def machine_payload() -> dict:
    return {
        "source_kind": "msx_capture",
        "state": "changed",
        "change_count": 1,
        "incarnation": "machine-a",
        "frame_number": 1,
        "screen": {"format": "rgb8", "width": 1, "height": 1, "rgb_base64": "AAAA"},
        "observation_seq": 1,
        "refreshing": False,
    }


def machine_dataset(machine: str) -> dict[str, object]:
    return {"type": "workspace_dataset_changed", "dataset": "machine_live", "machine": machine}


class SpectatorHandler(lane_fixture.LaneHandler):
    def do_GET(self) -> None:
        server = cast(SpectatorServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == LIVE_PATH:
            machine = urllib.parse.parse_qs(request.query).get("source_kind", ["unknown"])[0]
            label = "live:" + machine
            phase = server.record(label)
            if self.respond(200, machine_payload()):
                server.responded(phase, label)
            return
        if request.path == "/mcp":
            machine = urllib.parse.parse_qs(request.query).get("machine", ["watch"])[0]
            server.record("observer:" + machine)
        super().do_GET()

    def do_POST(self) -> None:
        if urllib.parse.urlsplit(self.path).path == "/api/v1/msx/tick":
            server = cast(SpectatorServer, self.server)
            phase = server.record("legacy-tick")
            if self.respond(500, {"error": "legacy tick is not SSE"}):
                server.responded(phase, "legacy-tick")
            return
        super().do_POST()


class SpectatorServer(lane_fixture.LaneServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = SpectatorHandler
        self.observer_restart_on_resume = False


class SpectatorPushTest(unittest.TestCase):
    binary = ""

    def test_visible_machine_reads_and_controlled_ticker(self) -> None:
        owed.ChatServer = SpectatorServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def scenario(server: owed.ChatServer, step: Callable[..., None]) -> None:
            spectator = cast(SpectatorServer, server)
            spectator.set_phase("open")
            step("keys", ":go Features\r")
            step("wait", lambda: spectator.response_count("open", lane_fixture.LANES) >= 1,
                 "Lanes did not open")
            step("drain", 0.3)
            step("keys", "jjjjjjjjj\r")
            step("wait", lambda: spectator.response_count("open", "live:msx_capture") >= 1,
                 "MSX did not open from its Lane row")
            step("drain", 1.2)
            self.assertEqual(spectator.response_count("open", "live:msx_capture"), 1)
            self.assertEqual(spectator.response_count("open", "live:dos_capture"), 0)

            spectator.set_phase("push")
            spectator.events.put(machine_dataset("msx"))
            step("wait", lambda: spectator.response_count("push", "live:msx_capture") == 1,
                 "the changed machine was not read once")
            spectator.events.put(machine_dataset("dos"))
            step("drain", 0.4)
            self.assertEqual(spectator.response_count("push", "live:dos_capture"), 0)
            self.assertEqual(spectator.count("push", "legacy-tick"), 0)

            spectator.set_phase("control")
            connections = spectator.observer_connections
            step("keys", "\x1b[15~")
            step("wait", lambda: spectator.observer_connections > connections
                 and spectator.count("control", "observer:msx") >= 1,
                 "Control did not reconnect with the machine query")
            spectator.set_phase("watch")
            connections = spectator.observer_connections
            step("keys", "\x1b[15~")
            step("wait", lambda: spectator.observer_connections > connections
                 and spectator.count("watch", "observer:watch") >= 1,
                 "Watch did not remove the machine query")
            self.assertEqual(spectator.count("watch", "legacy-tick"), 0)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_spectator_push.py /path/to/masc_tui.exe")
    SpectatorPushTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
