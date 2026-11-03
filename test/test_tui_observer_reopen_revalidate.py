"""A reopened observer feed re-reads the visible surfaces unless it replays
everything that was published while it was closed (RFC-0480 §3.3).

The fixture serves one observer stream that ends, then a second whose replay
header is the case under test and which stays open. The refresh cadence is
pushed out of the test's lifetime, so a dashboard read after the second stream
opens can only come from the reopen.
"""

from __future__ import annotations

import fcntl
import http.server
import json
import os
import pathlib
import pty
import select
import socketserver
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


SESSION = "fixture-session"
INSTANCE = "fixture-instance"
# The full refresh bundle reads this on every pass, whatever the surface.
BUNDLE_PATH = "/api/v1/dashboard/briefing"
WAIT_SECONDS = 25.0
QUIET_SECONDS = 3.0


class FeedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    request_queue_size = 128

    def __init__(
        self, base: str, *, reopen_instance: str, reopen_headers: list[tuple[str, str]]
    ) -> None:
        super().__init__(("127.0.0.1", 0), FeedHandler)
        self.base = os.path.realpath(base)
        self.reopen_instance = reopen_instance
        self.reopen_headers = reopen_headers
        self.condition = threading.Condition()
        self.bundle_reads = 0
        self.streams = 0
        self.bundle_reads_before_reopen: int | None = None
        self.reopened = threading.Event()
        self.release = threading.Event()

    def counts(self) -> tuple[int, int]:
        with self.condition:
            return self.bundle_reads, self.streams


class FeedHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:
        del format, args

    def respond(self, status: int, value: object) -> None:
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("x-masc-workspace-read", "matched-v1")
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self) -> None:
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if urllib.parse.urlsplit(self.path).path != "/mcp":
            self.respond(503, {"error": "fixture write unavailable"})
            return
        try:
            message = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.respond(400, {"error": "invalid request"})
            return
        if not isinstance(message, dict) or message.get("method") != "initialize":
            self.respond(503, {"error": "fixture method unavailable"})
            return
        payload = json.dumps({"jsonrpc": "2.0", "id": 1, "result": {}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Mcp-Session-Id", SESSION)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        server = cast(FeedServer, self.server)
        split = urllib.parse.urlsplit(self.path)
        if split.path == "/health":
            self.respond(
                200,
                {
                    "status": "ok",
                    "version": "fixture",
                    "build": {"binary_commit": "fixture"},
                    "paths": {
                        "effective_base_path": server.base,
                        "effective_masc_root": server.base + "/.masc",
                    },
                    "startup": {"state_ready": True},
                },
            )
            return
        if split.path == BUNDLE_PATH:
            with server.condition:
                server.bundle_reads += 1
                server.condition.notify_all()
            self.respond(200, {})
            return
        if split.path != "/mcp":
            self.respond(200, {})
            return
        query = urllib.parse.parse_qs(split.query)
        if query.get("expected_base_path") != [server.base] or query.get(
            "expected_masc_root"
        ) != [server.base + "/.masc"]:
            self.respond(409, {"error": "workspace precondition failed"})
            return
        with server.condition:
            index = server.streams
            server.streams += 1
            if index == 1:
                server.bundle_reads_before_reopen = server.bundle_reads
            server.condition.notify_all()
        if index == 0:
            # A live stream that ends: the TUI keeps its cursor and reconnects.
            event = b'id: 37\ndata: {"type":"fixture-control"}\n\n'
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("x-masc-workspace-read", "matched-v1")
            self.send_header("x-masc-sse-instance-id", INSTANCE)
            self.send_header("x-masc-sse-replay", "fresh")
            self.send_header("Content-Length", str(len(event)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(event)
            self.wfile.flush()
            self.close_connection = True
            return
        if index > 1:
            self.respond(503, {"error": "fixture completed"})
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("x-masc-workspace-read", "matched-v1")
        self.send_header("x-masc-sse-instance-id", server.reopen_instance)
        for name, value in server.reopen_headers:
            self.send_header(name, value)
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(b": fixture reopened\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            return
        server.reopened.set()
        server.release.wait(60)
        self.close_connection = True


class ObserverReopenRevalidateTest(unittest.TestCase):
    binary = ""

    def run_reopen(
        self, reopen_headers: list[tuple[str, str]], *, reopen_instance: str = INSTANCE
    ) -> tuple[int, int]:
        """The bundle reads seen before the reopen and once it settled."""
        with tempfile.TemporaryDirectory(prefix="masc-observer-reopen-") as base:
            config = pathlib.Path(base, ".masc", "config")
            config.mkdir(parents=True)
            (config / "runtime.toml").write_text(
                '[tui]\nopening = "overview"\nhints_visible = false\n'
                "help_hint_shown = true\nreduce_motion = true\n",
                encoding="utf-8",
            )
            server = FeedServer(
                base, reopen_instance=reopen_instance, reopen_headers=reopen_headers
            )
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            master, slave = pty.openpty()
            process: subprocess.Popen[bytes] | None = None
            try:
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
                        "--refresh",
                        "1000",
                    ],
                    stdin=slave,
                    stdout=slave,
                    stderr=slave,
                    env=env,
                    close_fds=True,
                )
                os.close(slave)
                slave = -1

                def drain_until(predicate: Callable[[], bool], label: str) -> None:
                    assert process is not None
                    deadline = time.monotonic() + WAIT_SECONDS
                    while time.monotonic() < deadline:
                        if predicate():
                            return
                        if process.poll() is not None:
                            break
                        if select.select([master], [], [], 0.05)[0]:
                            try:
                                os.read(master, 65536)
                            except OSError:
                                break
                    self.fail(f"{label}; exit={process.poll()}, counts={server.counts()}")

                drain_until(server.reopened.is_set, "the observer did not reconnect")
                quiet_until = time.monotonic() + QUIET_SECONDS
                drain_until(lambda: time.monotonic() >= quiet_until, "the TUI exited")
                before = server.bundle_reads_before_reopen
                assert before is not None
                return before, server.counts()[0]
            finally:
                server.release.set()
                if process is not None:
                    if process.poll() is None:
                        process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                if slave >= 0:
                    os.close(slave)
                os.close(master)
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)

    def test_reopen_after_a_gap_reads_the_visible_surfaces(self) -> None:
        before, after = self.run_reopen(
            [
                ("x-masc-sse-replay", "resumed-after-gap"),
                ("x-masc-sse-replay-missed-through", "40"),
            ]
        )
        self.assertGreater(after, before)

    def test_reopen_on_a_reset_reads_the_visible_surfaces(self) -> None:
        # A restarted server names a new instance; the old cursor cannot resume.
        before, after = self.run_reopen(
            [("x-masc-sse-replay", "reset-instance-changed")],
            reopen_instance="successor-instance",
        )
        self.assertGreater(after, before)

    def test_complete_replay_reads_nothing_more(self) -> None:
        before, after = self.run_reopen([("x-masc-sse-replay", "resumed")])
        self.assertEqual(after, before)


if __name__ == "__main__":
    ObserverReopenRevalidateTest.binary = os.path.abspath(sys.argv.pop(1))
    unittest.main()
