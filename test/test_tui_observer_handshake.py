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
from typing import Callable, Literal, cast


SESSION = "fixture-session"
INSTANCE = "fixture-instance"
CURSORS = {"37", "38", "500", "501", "502"}
Mode = Literal[
    "invalid",
    "resumed",
    "ahead",
    "media",
    "workspace",
    "workspace_transient",
    "missing",
    "conflict",
    "missing_after_live",
]


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

    def __init__(self, base: str, *, mode: Mode) -> None:
        super().__init__(("127.0.0.1", 0), ObserverHandler)
        self.base = os.path.realpath(base)
        self.mode = mode
        self.condition = threading.Condition()
        self.initializes = 0
        self.health_responses = 0
        self.health_failures = 0
        self.fail_next_health = False
        self.fleet_openings = 0
        self.release_fleet = threading.Event()
        self.requests: list[StreamRequest] = []
        self.sent: list[int] = []
        # The final request is recorded but held until cleanup.
        self.gates = [
            threading.Event() for _ in range(4 if mode in ("resumed", "media") else 3)
        ]

    def snapshot(self) -> tuple[int, int, list[StreamRequest], list[int]]:
        with self.condition:
            return (
                self.initializes,
                self.health_responses,
                list(self.requests),
                list(self.sent),
            )

    def fleet_count(self) -> int:
        with self.condition:
            return self.fleet_openings


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
            with server.condition:
                fail_health = server.fail_next_health
                server.fail_next_health = False
                if fail_health:
                    server.health_failures += 1
                    server.condition.notify_all()
            if fail_health:
                self.respond(503, {"error": "temporary identity outage"})
                return
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
            if server.mode == "workspace_transient":
                expected = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
                if expected.get("expected_base_path") != [server.base] or expected.get(
                    "expected_masc_root"
                ) != [server.base + "/.masc"]:
                    self.respond(409, {"error": "workspace precondition failed"})
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("x-masc-workspace-read", "matched-v1")
                self.send_header("Connection", "close")
                self.end_headers()
                try:
                    self.wfile.write(b": fixture fleet open\n\n")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    return
                with server.condition:
                    server.fleet_openings += 1
                    server.condition.notify_all()
                server.release_fleet.wait(30)
                self.close_connection = True
                return
            self.respond(503, {"error": "fleet stream unavailable in fixture"})
            return
        if path != "/mcp":
            self.respond(200, {})
            return

        expected = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        if expected.get("expected_base_path") != [server.base] or expected.get(
            "expected_masc_root"
        ) != [server.base + "/.masc"]:
            self.respond(409, {"error": "workspace precondition failed"})
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
        if server.mode in ("workspace", "workspace_transient") and index == 0:
            if server.mode == "workspace_transient":
                with server.condition:
                    server.fail_next_health = True
            self.respond(409, {"code": "workspace_precondition_failed"})
            with server.condition:
                server.sent.append(index)
                server.condition.notify_all()
            return
        missing_session = (server.mode in ("missing", "conflict") and index == 0) or (
            server.mode == "missing_after_live" and index == 1
        )
        if missing_session:
            self.respond(
                404 if server.mode in ("missing", "missing_after_live") else 409,
                {"error": "session lost"},
            )
            with server.condition:
                server.sent.append(index)
                server.condition.notify_all()
            return
        response_count = 3 if server.mode in ("resumed", "media") else 2
        if index >= response_count:
            self.respond(503, {"error": "fixture completed"})
            return

        content_type = "text/event-stream"
        if server.mode == "missing_after_live":
            headers = (
                f"x-masc-sse-instance-id: {INSTANCE}\r\nx-masc-sse-replay: fresh\r\n"
            )
            event_id = 37
            name = "fixture-control"
        elif server.mode == "workspace_transient":
            headers = (
                f"x-masc-sse-instance-id: {INSTANCE}\r\nx-masc-sse-replay: fresh\r\n"
            )
            event_id = 37
            name = "fixture-control"
        elif server.mode == "media":
            replay = "fresh" if index == 0 else "resumed"
            headers = (
                f"x-masc-sse-instance-id: {INSTANCE}\r\nx-masc-sse-replay: {replay}\r\n"
            )
            event_id = (37, 500, 38)[index]
            name = "fixture-rejected" if index == 1 else "fixture-control"
            if index == 1:
                content_type = "application/json"
        elif server.mode == "resumed" and index < 2:
            replay = "fresh" if index == 0 else "resumed"
            headers = (
                f"x-masc-sse-instance-id: {INSTANCE}\r\nx-masc-sse-replay: {replay}\r\n"
            )
            event_id = 37 + index
            name = "fixture-control"
        elif server.mode == "ahead":
            replay = "fresh" if index == 0 else "reset-cursor-ahead"
            headers = (
                f"x-masc-sse-instance-id: {INSTANCE}\r\nx-masc-sse-replay: {replay}\r\n"
            )
            event_id = 500 if index == 0 else 38
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
            f"HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\n{headers}"
            f"x-masc-workspace-read: matched-v1\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n"
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

    def run_scenario(self, *, mode: Mode) -> None:
        with tempfile.TemporaryDirectory(prefix="masc-observer-handshake-") as base:
            config = pathlib.Path(base, ".masc", "config")
            config.mkdir(parents=True)
            (config / "runtime.toml").write_text(
                '[tui]\nopening = "overview"\nhints_visible = false\n'
                "help_hint_shown = true\nreduce_motion = true\n",
                encoding="utf-8",
            )
            server = ObserverServer(base, mode=mode)
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
                        # Reconnects must not wait for this refresh cadence.
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
                        server.snapshot()[1] >= 2
                        and len(server.snapshot()[2]) >= 1
                        and (mode != "workspace_transient" or server.fleet_count() >= 1)
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
                if mode == "workspace_transient":
                    last_health = server.snapshot()[1]
                    quiet_since = time.monotonic()

                    def health_is_quiet() -> bool:
                        nonlocal last_health, quiet_since
                        count = server.snapshot()[1]
                        if count != last_health:
                            last_health = count
                            quiet_since = time.monotonic()
                        return time.monotonic() - quiet_since >= 1.0

                    wait_until(health_is_quiet, "startup health reads did not settle")
                initial_health = server.snapshot()[1]

                expected = (
                    [(None, "missing"), ("37", "fixture"), ("37", "fixture")]
                    if mode == "missing_after_live"
                    else [(None, "missing"), (None, "missing")]
                    if mode in ("missing", "conflict")
                    else [
                        (None, "missing"),
                        ("37", "fixture"),
                        ("38", "fixture"),
                        ("38", "fixture"),
                    ]
                    if mode == "resumed"
                    else [
                        (None, "missing"),
                        ("37", "fixture"),
                        ("37", "fixture"),
                        ("38", "fixture"),
                    ]
                    if mode == "media"
                    else [(None, "missing"), ("500", "fixture"), ("38", "fixture")]
                    if mode == "ahead"
                    else [(None, "missing"), (None, "missing")]
                    if mode in ("workspace", "workspace_transient")
                    else [(None, "missing"), (None, "missing"), (None, "missing")]
                )
                for index, (cursor, instance) in enumerate(expected):
                    wait_until(
                        lambda: len(server.snapshot()[2]) > index,
                        f"observer request {index + 1} did not arrive",
                    )
                    initializes, _, requests, _ = server.snapshot()
                    expected_initializes = (
                        2
                        if (mode in ("missing", "conflict") and index > 0)
                        or (mode == "missing_after_live" and index > 1)
                        else 1
                    )
                    self.assertEqual(
                        initializes,
                        expected_initializes,
                        "unexpected MCP initialization",
                    )
                    self.assertEqual(
                        requests[index],
                        StreamRequest(True, cursor, instance),
                        f"observer request {index + 1} lost its session or cursor",
                    )
                    if mode == "workspace" and index == 1:
                        self.assertGreater(
                            server.snapshot()[1],
                            initial_health,
                            "workspace refusal must require a new identity read",
                        )
                    if mode == "workspace_transient" and index == 1:
                        self.assertEqual(server.health_failures, 1)
                        self.assertGreater(
                            server.snapshot()[1],
                            initial_health,
                            "a later identity read must recover after the failed read",
                        )
                        wait_until(
                            lambda: server.fleet_count() >= 2,
                            "Fleet did not reopen after identity recovery",
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
                server.release_fleet.set()
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
        self.run_scenario(mode="invalid")

    def test_rejected_handshake_keeps_last_resumed_cursor(self) -> None:
        self.run_scenario(mode="resumed")

    def test_future_cursor_reset_accepts_lower_live_event(self) -> None:
        self.run_scenario(mode="ahead")

    def test_wrong_media_keeps_cursor_then_recovers(self) -> None:
        self.run_scenario(mode="media")

    def test_workspace_refusal_rechecks_identity_without_reinitializing(self) -> None:
        self.run_scenario(mode="workspace")

    def test_reconnect_after_transient_identity_failure(self) -> None:
        self.run_scenario(mode="workspace_transient")

    def test_missing_or_conflicting_session_is_reinitialized(self) -> None:
        for mode in ("missing", "conflict"):
            with self.subTest(mode=mode):
                self.run_scenario(mode=mode)

    def test_session_reinitialized_after_live_keeps_replay_cursor(self) -> None:
        self.run_scenario(mode="missing_after_live")


if __name__ == "__main__":
    ObserverHandshakeTest.binary = os.path.abspath(sys.argv.pop(1))
    unittest.main()
