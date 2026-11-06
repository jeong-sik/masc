#!/usr/bin/env python3
"""The visible Play room follows scoped SSE instead of successful polling."""

import json
import os
import sys
import threading
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed
import test_tui_lane_inventory_push as lane_fixture
import test_tui_spectator_push as spectator_fixture


ROOM_PATH = "/api/v1/play/room"


def room_event(machine: str) -> dict[str, object]:
    return {"type": "workspace_dataset_changed", "dataset": "play_room", "machine": machine}


def source_loss_event(sequence: int) -> dict[str, object]:
    return {
        "type": "agent_core:relay_subscription_loss",
        "event_type": "relay_subscription_loss",
        "ts_unix": 1.0,
        "payload": {"source_id": "play-room-fixture", "sequence": sequence, "dropped_count": 1},
    }


class PlayRoomHandler(spectator_fixture.SpectatorHandler):
    def observer_event_label(self) -> str:
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        machine = query.get("play_machine", ["none"])[0]
        client = query.get("play_client_id", ["none"])[0]
        return f"observer-play-event:{machine}:{client}"

    def do_GET(self) -> None:
        server = cast(PlayRoomServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == "/mcp":
            query = urllib.parse.parse_qs(request.query)
            machine = query.get("play_machine", ["none"])[0]
            client = query.get("play_client_id", ["none"])[0]
            server.record(f"observer-play:{machine}:{client}")
            if client != "none":
                with server.condition:
                    server.observer_play_clients.add(client)
        super().do_GET()

    def do_POST(self) -> None:
        server = cast(PlayRoomServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path != ROOM_PATH:
            super().do_POST()
            return
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        payload = json.loads(body)
        action = str(payload.get("action", ""))
        client = str(payload.get("client_id", ""))
        with server.condition:
            server.play_clients.add(client)
        phase = server.record("play:" + action)
        if action == "read" and server.hold_read.is_set():
            server.hold_read.clear()
            server.read_held.set()
            server.release_read.wait()
        sent = self.respond(
            200,
            {
                "viewer": "operator",
                "messages": [],
                "members": [],
                "has_more": False,
                "presence_seconds": 60.0,
            },
        )
        if sent:
            server.responded(phase, "play:" + action)


class PlayRoomServer(spectator_fixture.SpectatorServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = PlayRoomHandler
        self.hold_read = threading.Event()
        self.read_held = threading.Event()
        self.release_read = threading.Event()
        self.play_clients: set[str] = set()
        self.observer_play_clients: set[str] = set()


class PlayRoomPushTest(unittest.TestCase):
    binary = ""

    def test_scoped_reads_trailing_reconnect_and_hidden(self) -> None:
        owed.ChatServer = PlayRoomServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def scenario(server: owed.ChatServer, step: Callable[..., None]) -> None:
            room = cast(PlayRoomServer, server)
            room.set_phase("prime")
            room.events.put(room_event("dos"))
            step("wait", lambda: room.count("prime", "observer-play-event:none:none") == 1,
                 "the initial event did not establish an Observer cursor")
            step("drain", 0.2)

            room.set_phase("open")
            step("keys", ":go Features\r")
            step("wait", lambda: room.response_count("open", lane_fixture.LANES) >= 1,
                 "Lanes did not open")
            step("drain", 0.3)
            step("keys", "jjjjjjj\r")
            step("wait", lambda: room.response_count("open", "play:read") == 1,
                 "the Play room did not complete its initial read")
            step("drain", 2.4)
            self.assertEqual(room.response_count("open", "play:read"), 1,
                             "the Play room kept reading while idle")
            self.assertEqual(room.observer_play_clients, room.play_clients)
            self.assertEqual(len(room.play_clients), 1)
            self.assertEqual(room.count("open", "observer-play:msx:" + next(iter(room.play_clients))), 1)
            self.assertEqual(room.count("open", "legacy-tick"), 0)

            room.set_phase("changed")
            room.events.put(room_event("dos"))
            step("wait", lambda: room.response_count("changed", "play:read") == 1,
                 "a cross-machine Play event did not read the shared transcript")

            room.set_phase("trailing")
            room.hold_read.set()
            room.events.put(room_event("msx"))
            step("wait", room.read_held.is_set, "the first Play change read did not start")
            room.events.put(room_event("dos"))
            room.events.put(room_event("msx"))
            room.events.put(spectator_fixture.machine_dataset("msx"))
            step("wait", lambda: room.response_count("trailing", "live:msx_capture") == 1,
                 "the machine response did not establish that the Play burst was applied")
            room.release_read.set()
            step("wait", lambda: room.response_count("trailing", "play:read") == 2,
                 "a burst did not produce one trailing Play read")
            step("drain", 0.5)
            self.assertEqual(room.response_count("trailing", "play:read"), 2)

            room.set_phase("source-loss")
            room.events.put(source_loss_event(1))
            step("wait", lambda: room.response_count("source-loss", "play:read") == 1,
                 "a relay source loss did not revalidate the visible room")

            room.observer_gap_on_resume = True
            room.set_phase("reconnect")
            room.events.put("close")
            step("wait", lambda: room.response_count("reconnect", "play:read") == 1,
                 "an Observer replay gap did not revalidate the visible room")
            step("wait", lambda: room.count("reconnect", "observer-play:msx:" + next(iter(room.play_clients))) >= 1,
                 "the reconnected Observer lost its Play scope")

            room.observer_gap_on_resume = False
            room.set_phase("leaving")
            step("keys", "\x1b")
            step("wait", lambda: room.response_count("leaving", "play:leave") == 1,
                 "hiding the room did not release its previous HTTP presence")
            step("wait", lambda: room.count("leaving", "observer-play:none:none") >= 1,
                 "hiding the room did not remove its Observer Play scope")
            room.set_phase("hidden")
            room.events.put(room_event("dos"))
            step("wait", lambda: room.count("hidden", "observer-play-event:none:none") == 1,
                 "the hidden Observer did not receive the Play notification")
            room.events.put(lane_fixture.dataset("lanes"))
            step("wait", lambda: room.response_count("hidden", lane_fixture.LANES) == 1,
                 "the Lanes response did not establish that the hidden Play event was applied")
            self.assertEqual(room.count("hidden", "play:read"), 0,
                             "a hidden Play room still read after a notification")
            self.assertEqual(room.count("hidden", "legacy-tick"), 0)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_play_room_push.py /path/to/masc_tui.exe")
    PlayRoomPushTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
