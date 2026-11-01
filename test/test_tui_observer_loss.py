#!/usr/bin/env python3
"""Exercise observer-loss recovery in a TUI against an isolated HTTP peer."""

import fcntl
import json
import os
import pathlib
import pty
import queue
import re
import select
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import unittest
import urllib.parse
from typing import Callable, cast

from test_tui_fusion_recovery import FixtureHandler, FixtureServer


CHANGES_PATH = "/api/v1/keepers/analyst/file-changes"
HISTORY_PATH = "/api/v1/keepers/analyst/chat/history"


class LossServer(FixtureServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = LossHandler
        self.observer_ready = threading.Event()
        self.first_changes_started = threading.Event()
        self.release_first_changes = threading.Event()
        self.first_history_started = threading.Event()
        self.release_first_history = threading.Event()
        self.events: queue.Queue[tuple[int, int] | None] = queue.Queue()


class LossHandler(FixtureHandler):
    def do_POST(self) -> None:
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        payload = b'{"jsonrpc":"2.0","id":1,"result":{}}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Mcp-Session-Id", "loss-fixture-session")
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self) -> None:
        server = cast(LossServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == "/mcp":
            if urllib.parse.parse_qs(request.query).get("sse_kind") != ["observer"]:
                self.respond(400, {"error": "observer stream required"})
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("x-masc-sse-instance-id", "loss-fixture-instance")
            self.send_header("x-masc-sse-replay", "fresh")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.flush()
            server.observer_ready.set()
            while True:
                event = server.events.get()
                if event is None:
                    break
                cursor, sequence = event
                payload = json.dumps(
                    {
                        "type": "agent_core:relay_subscription_loss",
                        "event_type": "relay_subscription_loss",
                        "ts_unix": 1.0,
                        "payload": {
                            "source_id": "fixture-source",
                            "sequence": sequence,
                            "dropped_count": 2,
                        },
                    }
                ).encode()
                try:
                    self.wfile.write(
                        f"id: {cursor}\ndata: ".encode() + payload + b"\n\n"
                    )
                    self.wfile.flush()
                    server.record("observer-event-written")
                except (BrokenPipeError, ConnectionResetError):
                    break
            self.close_connection = True
        elif request.path == HISTORY_PATH:
            phase = server.record(request.path)
            if phase == "chat-first":
                server.first_history_started.set()
                server.release_first_history.wait()
            if self.respond(200, []):
                server.responded(phase, request.path)
        elif request.path == HISTORY_PATH + "/page":
            self.respond(
                200,
                {
                    "schema": "masc.keeper_chat_history.page.v2",
                    "messages": [],
                    "has_more": False,
                    "next_cursor": None,
                },
            )
        elif request.path == "/api/v1/keepers/analyst/memory-journal":
            self.respond(200, {"entries": []})
        elif request.path == CHANGES_PATH:
            phase = server.record(request.path)
            if phase == "first":
                server.first_changes_started.set()
                server.release_first_changes.wait()
            snapshot = {
                "keeper": "analyst",
                "window_hours": 24.0,
                "calls_in_window": 0,
                "changes": [],
                "over_budget": 0,
                "malformed": 0,
            }
            if self.respond(200, snapshot, workspace_receipt=True):
                server.responded(phase, request.path)
        else:
            super().do_GET()


class ObserverLossTest(unittest.TestCase):
    binary = ""

    def test_loss_revalidates_and_retires_hidden_reading(self) -> None:
        with tempfile.TemporaryDirectory(prefix="masc-observer-loss-") as temp_base:
            base = os.path.realpath(temp_base)
            config = pathlib.Path(base, ".masc", "config")
            keepers = config / "keepers"
            keepers.mkdir(parents=True)
            (config / "runtime.toml").write_text(
                '[tui]\nopening = "overview"\nhints_visible = false\n'
                "help_hint_shown = true\nreduce_motion = true\n",
                encoding="utf-8",
            )
            (keepers / "analyst.toml").write_text(
                '[keeper]\ninstructions = "Fixture"\n', encoding="utf-8"
            )
            server = LossServer(base)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 35, 200, 0, 0))
            process = subprocess.Popen(
                [
                    self.binary,
                    "--base-path",
                    base,
                    "--port",
                    str(server.server_port),
                    "--refresh",
                    "1000",
                ],
                stdin=slave,
                stdout=slave,
                stderr=slave,
                cwd=base,
                env={"PATH": os.defpath, "TERM": "xterm-256color", "LANG": "C.UTF-8"},
                close_fds=True,
            )
            os.close(slave)
            output = bytearray()

            def drain_for(seconds: float) -> None:
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    if select.select([master], [], [], 0.05)[0]:
                        try:
                            output.extend(os.read(master, 65536))
                        except OSError:
                            return

            def wait_until(predicate: Callable[[], bool], label: str) -> None:
                deadline = time.monotonic() + 25.0
                while time.monotonic() < deadline:
                    if predicate():
                        return
                    if process.poll() is not None:
                        break
                    drain_for(0.05)
                terminal_tail = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", bytes(output))[
                    -3000:
                ]
                raw_fd, raw_path = tempfile.mkstemp(
                    prefix="masc-observer-loss-", suffix=".ansi"
                )
                with os.fdopen(raw_fd, "wb") as raw_capture:
                    raw_capture.write(output)
                self.fail(
                    f"{label}; exit={process.poll()}, requests={server.requests!r}, "
                    f"raw={raw_path}, terminal tail={terminal_tail!r}"
                )

            def keys(text: str) -> None:
                for key in text.encode():
                    os.write(master, bytes([key]))
                    time.sleep(0.03)

            try:
                wait_until(
                    lambda: (
                        server.response_count("setup", "/health") >= 2
                        and server.observer_ready.is_set()
                    ),
                    "workspace and observer were not ready",
                )
                drain_for(1.0)
                keys("\t\t")
                drain_for(0.3)
                keys("r")
                drain_for(1.0)
                server.set_phase("first")
                keys("i")
                drain_for(0.3)
                keys("/activity changes\r")
                wait_until(
                    server.first_changes_started.is_set,
                    "first file changes read did not start",
                )
                server.set_phase("loss")
                server.events.put((1, 1))
                wait_until(
                    lambda: server.count("loss", "observer-event-written") == 1,
                    "first loss event was not sent",
                )
                server.events.put((2, 2))
                wait_until(
                    lambda: server.count("loss", "observer-event-written") == 2,
                    "second loss event was not sent",
                )
                drain_for(0.8)
                self.assertEqual(server.count("loss", CHANGES_PATH), 0)
                server.release_first_changes.set()
                wait_until(
                    lambda: server.response_count("first", CHANGES_PATH) == 1,
                    "first read was not released",
                )
                wait_until(
                    lambda: server.response_count("loss", CHANGES_PATH) == 1,
                    "losses did not cause one follow-up read",
                )
                server.set_phase("duplicate")
                server.events.put((3, 2))
                wait_until(
                    lambda: server.count("duplicate", "observer-event-written") == 1,
                    "duplicate event was not sent",
                )
                drain_for(0.8)
                self.assertEqual(server.count("duplicate", CHANGES_PATH), 0)
                # At this terminal width the activity layout cycles narrow,
                # wide, hidden, then narrow again.
                keys("\x0c\x0c")
                drain_for(0.3)
                server.set_phase("hidden")
                server.events.put((4, 3))
                wait_until(
                    lambda: server.count("hidden", "observer-event-written") == 1,
                    "hidden event was not sent",
                )
                drain_for(0.5)
                self.assertEqual(server.count("hidden", CHANGES_PATH), 0)
                server.set_phase("reopened")
                keys("\x0c")
                wait_until(
                    lambda: server.response_count("reopened", CHANGES_PATH) == 1,
                    "reopened Changes pane did not request a fresh reading",
                )
                server.set_phase("chat-first")
                keys("c")
                wait_until(
                    server.first_history_started.is_set, "chat history did not start"
                )
                server.set_phase("chat-loss")
                server.events.put((5, 4))
                wait_until(
                    lambda: server.response_count("chat-loss", CHANGES_PATH) >= 1,
                    "the first chat loss was not applied",
                )
                server.events.put((6, 5))
                wait_until(
                    lambda: server.count("chat-loss", "observer-event-written") == 2,
                    "chat loss events were not sent",
                )
                wait_until(
                    lambda: server.response_count("chat-loss", CHANGES_PATH) == 2,
                    "the second chat loss was not applied",
                )
                drain_for(0.8)
                self.assertEqual(server.count("chat-loss", HISTORY_PATH), 0)
                server.release_first_history.set()
                wait_until(
                    lambda: server.response_count("chat-loss", HISTORY_PATH) == 1,
                    "chat losses did not cause one follow-up history read",
                )
                drain_for(0.5)
                self.assertEqual(server.count("chat-loss", HISTORY_PATH), 1)
            finally:
                server.release_first_changes.set()
                server.release_first_history.set()
                server.events.put(None)
                server.release_recovery.set()
                server.release_recovery_health.set()
                if process.poll() is None:
                    process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                os.close(master)
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_observer_loss.py /path/to/masc_tui.exe")
    ObserverLossTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
