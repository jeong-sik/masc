#!/usr/bin/env python3
"""Exercise an observer SSE event through the TUI's workspace-bound Fusion reads."""

import fcntl
import json
import os
import pathlib
import pty
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

from test_tui_fusion_recovery import (
    DETAIL_PATH,
    LIST_PATH,
    RUN,
    FixtureHandler,
    FixtureServer,
)


class StreamServer(FixtureServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = StreamHandler
        self.observer_requested = threading.Event()
        self.allow_open = threading.Event()
        self.observer_ready = threading.Event()
        self.emit_event = threading.Event()
        self.event_sent = threading.Event()
        self.finish_stream = threading.Event()
        self.observer_session_valid = False


class StreamHandler(FixtureHandler):
    def do_POST(self) -> None:
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        payload = b'{"jsonrpc":"2.0","id":1,"result":{}}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Mcp-Session-Id", "fixture-session")
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self) -> None:
        server = cast(StreamServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path != "/mcp":
            super().do_GET()
            return
        if urllib.parse.parse_qs(request.query, keep_blank_values=True).get(
            "sse_kind"
        ) != ["observer"]:
            self.respond(400, {"error": "observer stream required"})
            return
        expected = urllib.parse.parse_qs(request.query)
        if expected.get("expected_base_path") != [
            os.path.realpath(server.base)
        ] or expected.get("expected_masc_root") != [
            os.path.realpath(server.base) + "/.masc"
        ]:
            self.respond(409, {"error": "workspace precondition failed"})
            return
        server.observer_session_valid = (
            self.headers.get("Mcp-Session-Id") == "fixture-session"
        )
        server.observer_requested.set()
        server.allow_open.wait()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("x-masc-sse-instance-id", "fixture-instance")
        self.send_header("x-masc-sse-replay", "fresh")
        self.send_header("x-masc-workspace-read", "matched-v1")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.flush()
        server.observer_ready.set()
        server.emit_event.wait()
        data = json.dumps({"type": "fusion_run_status", "run": RUN}).encode()
        try:
            self.wfile.write(b"id: 37\ndata: " + data + b"\n\n")
            self.wfile.flush()
            server.event_sent.set()
        except (BrokenPipeError, ConnectionResetError):
            pass
        server.finish_stream.wait()
        self.close_connection = True


class FusionSseTest(unittest.TestCase):
    binary = ""

    def test_observer_event_refreshes_open_fusion_without_cadence(self) -> None:
        with tempfile.TemporaryDirectory(prefix="masc-fusion-sse-") as base:
            config = pathlib.Path(base, ".masc", "config")
            config.mkdir(parents=True)
            (config / "runtime.toml").write_text(
                '[tui]\nopening = "overview"\nhints_visible = false\n'
                "help_hint_shown = true\nreduce_motion = true\n",
                encoding="utf-8",
            )
            server = StreamServer(base)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 35, 140, 0, 0))
            env = {
                "HOME": base,
                "TMPDIR": base,
                "PATH": os.defpath,
                "TERM": "xterm-256color",
                "LANG": "C.UTF-8",
            }
            process = subprocess.Popen(
                [
                    self.binary,
                    "--base-path",
                    base,
                    "--port",
                    str(server.server_port),
                ],
                stdin=slave,
                stdout=slave,
                stderr=slave,
                env=env,
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
                    if process.poll() is not None:
                        break
                    if predicate():
                        return
                    drain_for(0.05)
                self.fail(
                    f"{label}; exit={process.poll()}, requests={server.requests!r}, "
                    f"terminal tail={bytes(output[-3000:])!r}"
                )

            def keys(text: str) -> None:
                for key in text.encode():
                    os.write(master, bytes([key]))
                    time.sleep(0.03)

            try:
                wait_until(
                    lambda: (
                        server.response_count("setup", "/health") >= 2
                        and server.observer_requested.is_set()
                    ),
                    "workspace and observer were not ready",
                )
                self.assertTrue(server.observer_session_valid)
                drain_for(1.0)
                keys(":")
                drain_for(0.3)
                keys("fusion\r")
                wait_until(
                    lambda: b"setup-list" in output,
                    "initial list fixture was not applied",
                )
                drain_for(0.7)
                keys("\r")
                wait_until(
                    lambda: b"setup-detail" in output,
                    "initial detail fixture was not applied",
                )
                # Opening an observer also revalidates visible Fusion data.
                # Hold its headers until the detail is open, then wait for
                # both uniquely tagged results before testing the event.
                server.set_phase("opened")
                server.allow_open.set()
                wait_until(server.observer_ready.is_set, "observer was not opened")
                wait_until(
                    lambda: b"opened-list" in output and b"opened-detail" in output,
                    "observer-open fixtures were not applied",
                )
                server.set_phase("quiet")
                drain_for(1.0)
                self.assertEqual(server.count("quiet", LIST_PATH), 0)
                self.assertEqual(server.count("quiet", DETAIL_PATH), 0)
                server.set_phase("event")
                server.emit_event.set()
                wait_until(server.event_sent.is_set, "observer event was not sent")
                wait_until(
                    lambda: b"event-list" in output and b"event-detail" in output,
                    "event fixtures were not applied",
                )
                drain_for(1.0)
                self.assertEqual(server.count("event", LIST_PATH), 1)
                self.assertEqual(server.count("event", DETAIL_PATH), 1)
                self.assertIsNone(process.poll())
            finally:
                server.allow_open.set()
                server.emit_event.set()
                server.finish_stream.set()
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
        raise SystemExit("usage: test_tui_fusion_sse.py /path/to/masc_tui.exe")
    FusionSseTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
