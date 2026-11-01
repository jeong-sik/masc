#!/usr/bin/env python3
"""Exercise observer reconnects in a TUI connected to a loopback HTTP peer."""

import dataclasses
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
CURSORS = {"37", "38", "500", "501", "502"}


@dataclasses.dataclass(frozen=True)
class StreamRequest:
    # Only comparisons against fixture values are retained, never raw headers.
    session_matches: bool
    cursor: str | None
    instance: str


class ObserverServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    # A TUI startup requests several surfaces at once; do not drop its health
    # probe just because the fixture's accept queue is smaller than the burst.
    request_queue_size = 128

    def __init__(self, base: str, *, resumed: bool) -> None:
        super().__init__(("127.0.0.1", 0), ObserverHandler)
        self.base = os.path.realpath(base)
        self.resumed = resumed
        self.condition = threading.Condition()
        self.initializes = 0
        self.health_responses = 0
        self.requests: list[StreamRequest] = []
        self.sent: list[int] = []
        # The final request is recorded but held until cleanup.
        self.gates = [threading.Event() for _ in range(4 if resumed else 3)]

    def snapshot(self) -> tuple[int, int, list[StreamRequest], list[int]]:
        with self.condition:
            return (
                self.initializes,
                self.health_responses,
                list(self.requests),
                list(self.sent),
            )


class ObserverHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle(self) -> None:
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            # A rejected handshake closes the peer while the fixture can
            # still be waiting for the next keep-alive request.
            pass

    def log_message(self, format: str, *_args: object) -> None:
        pass

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
        if (
            not isinstance(message, dict)
            or cast(dict[str, object], message).get("method") != "initialize"
        ):
            self.respond(503, {"error": "fixture method unavailable"})
            return
        server = cast(ObserverServer, self.server)
        with server.condition:
            server.initializes += 1
            server.condition.notify_all()
        payload = json.dumps({"jsonrpc": "2.0", "id": 1, "result": {}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Mcp-Session-Id", SESSION)
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self) -> None:
        server = cast(ObserverServer, self.server)
        path = urllib.parse.urlsplit(self.path).path
        if path == "/health":
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
            with server.condition:
                server.health_responses += 1
                server.condition.notify_all()
            return
        if path == "/api/v1/stream/fleet":
            self.respond(503, {"error": "fleet stream unavailable in fixture"})
            return
        if path != "/mcp":
            self.respond(200, {})
            return

        cursor = self.headers.get("Last-Event-ID")
        if cursor is not None and cursor not in CURSORS:
            cursor = "<unexpected>"
        raw_instance = self.headers.get("x-masc-sse-instance-id")
        instance = (
            "missing"
            if raw_instance is None
            else "fixture"
            if raw_instance == INSTANCE
            else "<unexpected>"
        )
        request = StreamRequest(
            session_matches=self.headers.get("Mcp-Session-Id") == SESSION,
            cursor=cursor,
            instance=instance,
        )
        with server.condition:
            index = len(server.requests)
            server.requests.append(request)
            server.condition.notify_all()
        if index >= len(server.gates) or not server.gates[index].wait(30):
            self.respond(503, {"error": "fixture gate unavailable"})
            return
        response_count = 3 if server.resumed else 2
        if index >= response_count:
            self.respond(503, {"error": "fixture completed"})
            return

        if server.resumed and index < 2:
            replay = "fresh" if index == 0 else "resumed"
            headers = (
                f"x-masc-sse-instance-id: {INSTANCE}\r\nx-masc-sse-replay: {replay}\r\n"
            )
            event_id = 37 + index
            name = "fixture-control"
        else:
            # Conflicting duplicates must reject the entire response, including
            # an event delivered in the same network write as these headers.
            headers = (
                f"x-masc-sse-instance-id: {INSTANCE}\r\n"
                "X-Masc-Sse-Instance-Id: conflicting-instance\r\n"
                "x-masc-sse-replay: fresh\r\n"
            )
            event_id = 500 + index
            name = "fixture-rejected"
        body = f'id: {event_id}\ndata: {{"type":"{name}"}}\n\n'.encode()
        wire = (
            f"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n{headers}"
            f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n"
        ).encode() + body
        try:
            self.wfile.write(wire)
            self.wfile.flush()
            with server.condition:
                server.sent.append(index)
                server.condition.notify_all()
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True


class ObserverHandshakeTest(unittest.TestCase):
    binary = ""

    def run_scenario(self, *, resumed: bool) -> None:
        with tempfile.TemporaryDirectory(prefix="masc-observer-handshake-") as base:
            config = pathlib.Path(base, ".masc", "config")
            config.mkdir(parents=True)
            (config / "runtime.toml").write_text(
                '[tui]\nopening = "overview"\nhints_visible = false\n'
                "help_hint_shown = true\nreduce_motion = true\n",
                encoding="utf-8",
            )
            server = ObserverServer(base, resumed=resumed)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            master, slave = pty.openpty()
            process: subprocess.Popen[bytes] | None = None
            try:
                fcntl.ioctl(
                    slave, termios.TIOCSWINSZ, struct.pack("HHHH", 35, 140, 0, 0)
                )
                # Do not inherit credentials, proxy settings, or the live MASC base.
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
                        "4",
                    ],
                    stdin=slave,
                    stdout=slave,
                    stderr=slave,
                    env=env,
                    close_fds=True,
                )
                os.close(slave)
                slave = -1

                def wait_until(predicate: Callable[[], bool], label: str) -> None:
                    assert process is not None
                    deadline = time.monotonic() + 25.0
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
                    initializes, health, requests, sent = server.snapshot()
                    self.fail(
                        f"{label}; exit={process.poll()}, initialize count={initializes}, health={health}, "
                        f"requests={requests!r}, responses written={sent!r}"
                    )

                # Let the first workspace identity reads settle before releasing
                # the blocked stream. A replacement during setup is reported as
                # a fixture failure, not mistaken for a replay attempt.
                wait_until(
                    lambda: (
                        server.snapshot()[1] >= 2 and len(server.snapshot()[2]) >= 1
                    ),
                    "initial workspace and observer were not ready",
                )
                stable = server.snapshot()[0:1] + (len(server.snapshot()[2]),)
                stable_until = time.monotonic() + 1.0
                wait_until(
                    lambda: time.monotonic() >= stable_until, "startup did not settle"
                )
                self.assertEqual(
                    server.snapshot()[0:1] + (len(server.snapshot()[2]),),
                    stable,
                    "observer was replaced while the initial workspace settled",
                )

                expected = (
                    [
                        (None, "missing"),
                        ("37", "fixture"),
                        ("38", "fixture"),
                        ("38", "fixture"),
                    ]
                    if resumed
                    else [(None, "missing"), (None, "missing"), (None, "missing")]
                )
                for index, (cursor, instance) in enumerate(expected):
                    wait_until(
                        lambda: len(server.snapshot()[2]) > index,
                        f"observer request {index + 1} did not arrive",
                    )
                    initializes, _, requests, _ = server.snapshot()
                    self.assertEqual(initializes, 1, "MCP must initialize only once")
                    self.assertEqual(
                        requests[index],
                        StreamRequest(True, cursor, instance),
                        f"observer request {index + 1} lost its session or cursor",
                    )
                    if index + 1 < len(expected):
                        server.gates[index].set()
                        wait_until(
                            lambda: index in server.snapshot()[3],
                            f"observer response {index + 1} was not written",
                        )
            finally:
                for gate in server.gates:
                    gate.set()
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

    def test_invalid_handshakes_preserve_session_and_empty_cursor(self) -> None:
        self.run_scenario(resumed=False)

    def test_rejected_handshake_keeps_last_resumed_cursor(self) -> None:
        self.run_scenario(resumed=True)


if __name__ == "__main__":
    ObserverHandshakeTest.binary = os.path.abspath(sys.argv.pop(1))
    unittest.main()
