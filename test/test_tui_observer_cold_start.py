#!/usr/bin/env python3
"""Check cold TUI admission through a workspace-bound Observer."""

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
from typing import Callable, Literal, cast

Mode = Literal["attested", "unattested", "partial", "foreign", "unready"]
SESSION = "cold-fixture-session"
INSTANCE = "cold-fixture-instance"


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    request_queue_size = 128

    def __init__(self, base: str, mode: Mode) -> None:
        super().__init__(("127.0.0.1", 0), Handler)
        self.base = os.path.realpath(base)
        self.mode = mode
        self.lock = threading.Lock()
        self.health = 0
        self.initializes = 0
        self.observers = 0
        self.cursors: list[str | None] = []
        self.fleet = 0
        self.other = 0
        self.release = threading.Event()

    def counts(self) -> tuple[int, int, int, int, int]:
        with self.lock:
            return self.health, self.initializes, self.observers, self.fleet, self.other

    def observer_cursors(self) -> list[str | None]:
        with self.lock:
            return list(self.cursors)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *_args: object) -> None:
        pass

    def handle(self) -> None:
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def json_response(
        self, status: int, body: object, *, session: bool = False
    ) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if session:
            self.send_header("Mcp-Session-Id", SESSION)
        self.send_header("x-masc-workspace-read", "matched-v1")
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self) -> None:
        server = cast(Server, self.server)
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if urllib.parse.urlsplit(self.path).path != "/mcp":
            self.json_response(503, {"error": "fixture write unavailable"})
            return
        if json.loads(body).get("method") != "initialize":
            self.json_response(503, {"error": "fixture method unavailable"})
            return
        with server.lock:
            server.initializes += 1
        self.json_response(200, {"jsonrpc": "2.0", "id": 1, "result": {}}, session=True)

    def do_GET(self) -> None:
        server = cast(Server, self.server)
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == "/health":
            with server.lock:
                server.health += 1
            self.json_response(503, {"error": "health unavailable"})
            return
        if parsed.path in ("/mcp", "/api/v1/stream/fleet"):
            expected = urllib.parse.parse_qs(parsed.query)
            if expected.get("expected_base_path") != [server.base] or expected.get(
                "expected_masc_root"
            ) != [server.base + "/.masc"]:
                self.json_response(409, {"code": "workspace_precondition_failed"})
                return
            if parsed.path == "/mcp":
                if self.headers.get("Mcp-Session-Id") != SESSION:
                    self.json_response(404, {"error": "session unavailable"})
                    return
                with server.lock:
                    server.observers += 1
                    server.cursors.append(self.headers.get("Last-Event-ID"))
                if server.mode == "foreign":
                    self.json_response(409, {"code": "workspace_precondition_failed"})
                    return
                if server.mode == "unready":
                    self.json_response(503, {"error": "server not ready"})
                    return
            else:
                with server.lock:
                    server.fleet += 1
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("x-masc-workspace-read", "matched-v1")
            if parsed.path == "/mcp":
                self.send_header("x-masc-sse-instance-id", INSTANCE)
                self.send_header("x-masc-sse-replay", "fresh")
                if server.mode in ("attested", "partial"):
                    self.send_header("x-masc-observer-identity", "v1")
                if server.mode == "attested":
                    self.send_header("x-masc-observer-version", "fixture")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b'id: 37\ndata: {"type":"fixture-control"}\n\n')
            self.wfile.flush()
            server.release.wait(30)
            self.close_connection = True
            return
        with server.lock:
            server.other += 1
        self.json_response(200, {})


class ColdObserverTest(unittest.TestCase):
    binary = ""

    def run_scenario(self, mode: Mode) -> None:
        with tempfile.TemporaryDirectory(prefix="masc-observer-cold-") as base:
            config = pathlib.Path(base, ".masc", "config")
            config.mkdir(parents=True)
            (config / "runtime.toml").write_text(
                '[tui]\nopening = "overview"\nhints_visible = false\n'
                "help_hint_shown = true\nreduce_motion = true\n",
                encoding="utf-8",
            )
            server = Server(base, mode)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            master, slave = pty.openpty()
            process: subprocess.Popen[bytes] | None = None
            try:
                fcntl.ioctl(
                    slave, termios.TIOCSWINSZ, struct.pack("HHHH", 35, 140, 0, 0)
                )
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
                    env={
                        "HOME": base,
                        "TMPDIR": base,
                        "PATH": os.defpath,
                        "TERM": "xterm-256color",
                        "LANG": "C.UTF-8",
                    },
                    close_fds=True,
                )
                os.close(slave)
                slave = -1

                def wait_until(
                    predicate: Callable[[], bool], label: str, timeout: float = 12
                ) -> None:
                    assert process is not None
                    deadline = time.monotonic() + timeout
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
                    self.fail(
                        f"{label}; exit={process.poll()}, counts={server.counts()}"
                    )

                wait_until(
                    lambda: server.counts()[2] >= 1, "cold Observer did not open"
                )
                if mode == "attested":
                    wait_until(
                        lambda: server.counts()[2] >= 2 and server.counts()[3] >= 1,
                        "attested cold Observer did not admit normal streams",
                    )
                    self.assertEqual(
                        server.counts()[1], 1, "MCP session was not reused"
                    )
                    self.assertEqual(
                        server.observer_cursors()[:2],
                        [None, None],
                        "recovery-only events advanced the normal Observer cursor",
                    )
                else:
                    initial_health = server.counts()[0]
                    until = time.monotonic() + 4
                    wait_until(
                        lambda: time.monotonic() >= until, "fixture did not settle"
                    )
                    self.assertEqual(
                        server.counts()[3], 0, "unattested workspace opened Fleet"
                    )
                    self.assertEqual(
                        server.counts()[0],
                        initial_health,
                        "cold recovery polled health",
                    )
                    if mode == "unattested":
                        self.assertEqual(
                            server.counts()[2],
                            1,
                            "unattested stream opened normal Observer",
                        )
                self.assertGreaterEqual(server.counts()[0], 1)
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

    def test_attested_cold_start_with_health_unavailable(self) -> None:
        self.run_scenario("attested")

    def test_unattested_cold_start_stays_unconfirmed(self) -> None:
        self.run_scenario("unattested")

    def test_partial_foreign_and_unready_stay_unconfirmed(self) -> None:
        for mode in ("partial", "foreign", "unready"):
            with self.subTest(mode=mode):
                self.run_scenario(mode)


if __name__ == "__main__":
    ColdObserverTest.binary = os.path.abspath(sys.argv.pop(1))
    unittest.main()
