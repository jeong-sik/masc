#!/usr/bin/env python3
"""Exercise Fusion authority recovery in the TUI with a local HTTP peer."""

import collections
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
import urllib.parse
import unittest
from typing import Any, Callable, cast


RUN: dict[str, Any] = {
    "run_id": "a",
    "keeper": "analyst",
    "preset": "trio",
    "topology": "simple",
    "started_at": 1.0,
    "finished_at": None,
    "status": "running",
    "stage": "accepted",
    "progress": {},
}
LIST_PATH = "/api/v1/dashboard/fusion-runs"
DETAIL_PATH = LIST_PATH + "/a"


class FixtureServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    request_queue_size = 128

    def __init__(self, base: str) -> None:
        super().__init__(("127.0.0.1", 0), FixtureHandler)
        self.base = base
        self.phase = "setup"
        self.requests: collections.Counter[tuple[str, str]] = collections.Counter()
        self.responses: collections.Counter[tuple[str, str]] = collections.Counter()
        self.condition = threading.Condition()
        self.release_recovery = threading.Event()
        self.release_recovery_health = threading.Event()

    def record(self, path: str) -> str:
        with self.condition:
            phase = self.phase
            self.requests[(phase, path)] += 1
            self.condition.notify_all()
            return phase

    def set_phase(self, phase: str) -> None:
        with self.condition:
            self.phase = phase

    def count(self, phase: str, path: str) -> int:
        with self.condition:
            return self.requests[(phase, path)]

    def responded(self, phase: str, path: str) -> None:
        with self.condition:
            self.responses[(phase, path)] += 1
            self.condition.notify_all()

    def response_count(self, phase: str, path: str) -> int:
        with self.condition:
            return self.responses[(phase, path)]


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *_args: object) -> None:
        pass

    def respond(
        self, status: int, value: object, *, workspace_receipt: bool = False
    ) -> bool:
        data = json.dumps(value).encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            if workspace_receipt:
                self.send_header("x-masc-workspace-read", "matched-v1")
            self.end_headers()
            self.wfile.write(data)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            return False
        return True

    def do_POST(self) -> None:
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.respond(503, {"error": "observer unavailable in fixture"})

    def do_GET(self) -> None:
        server = cast(FixtureServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        path = request.path
        phase = server.record(path)
        if path == "/health":
            if phase == "recovery":
                server.release_recovery_health.wait()
            if phase == "unconfirmed":
                sent = self.respond(503, {"error": "health unavailable"})
            else:
                base = server.base
                sent = self.respond(
                    200,
                    {
                        "status": "ok",
                        "version": "fixture",
                        "build": {"binary_commit": "fixture"},
                        "paths": {
                            "effective_base_path": base,
                            "effective_masc_root": base + "/.masc",
                        },
                        "startup": {"state_ready": True},
                    },
                )
            if sent:
                server.responded(phase, path)
        elif path in (LIST_PATH, DETAIL_PATH):
            expected = urllib.parse.parse_qs(request.query)
            base = os.path.realpath(server.base)
            if expected.get("expected_base_path") != [base] or expected.get(
                "expected_masc_root"
            ) != [base + "/.masc"]:
                self.respond(409, {"error": "workspace precondition failed"})
                return
            # Hold both recovery reads so duplicate After_change demands must
            # queue a follow-up before either response is applied.
            if phase == "recovery":
                server.release_recovery.wait()
            run = dict(RUN)
            if phase in ("setup", "recovery", "opened", "event"):
                run["keeper"] = f"{phase}-{'list' if path == LIST_PATH else 'detail'}"
            if path == LIST_PATH:
                body = {
                    "generated_at": "now",
                    "count": 1,
                    "runs": [run],
                    "replay": {"status": "not_replayed"},
                    "historical_evidence": [],
                }
            else:
                body = {
                    "generated_at": "now",
                    "run": run,
                    "evidence": {"status": "pending", "post": None},
                }
            if self.respond(200, body, workspace_receipt=True):
                server.responded(phase, path)
        elif path == "/api/v1/stream/fleet":
            self.respond(503, {"error": "fleet stream unavailable in fixture"})
        else:
            self.respond(200, {}, workspace_receipt=True)


class FusionRecoveryTest(unittest.TestCase):
    binary = ""

    def test_recovery_reads_list_and_open_detail_once(self) -> None:
        with tempfile.TemporaryDirectory(prefix="masc-fusion-recovery-") as base:
            config = pathlib.Path(base, ".masc", "config")
            config.mkdir(parents=True)
            (config / "runtime.toml").write_text(
                '[tui]\nopening = "overview"\nhints_visible = false\n'
                "help_hint_shown = true\nreduce_motion = true\n",
                encoding="utf-8",
            )
            server = FixtureServer(base)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 35, 140, 0, 0))
            # The loopback peer is a fixture; do not pass live MASC credentials
            # or the user's runtime configuration to the child process.
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

            def wait_until(
                predicate: Callable[[], bool], label: str, timeout: float = 12.0
            ) -> None:
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        break
                    if predicate():
                        return
                    if select.select([master], [], [], 0.05)[0]:
                        try:
                            output.extend(os.read(master, 65536))
                        except OSError:
                            break
                self.fail(
                    f"{label}; process={process.poll()}, requests={server.requests}, "
                    f"terminal tail={bytes(output[-3000:])!r}"
                )

            def keys(text: str) -> None:
                for key in text.encode():
                    os.write(master, bytes([key]))
                    time.sleep(0.03)

            def drain_for(seconds: float) -> None:
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    if select.select([master], [], [], 0.05)[0]:
                        output.extend(os.read(master, 65536))

            try:
                wait_until(
                    lambda: server.response_count("setup", "/health") >= 2,
                    "initial workspace identity confirmed",
                )
                drain_for(1.0)
                keys(":")
                drain_for(0.3)
                keys("fusion")
                drain_for(0.3)
                keys("\r")
                wait_until(
                    lambda: b"setup-list" in output,
                    "initial list fixture was not applied",
                )
                # If the initial probe's reading was withdrawn during startup,
                # explicitly confirm the fixture before selecting a run.
                keys("r")
                wait_until(
                    lambda: server.response_count("setup", LIST_PATH) >= 2,
                    "Fusion list ready",
                )
                drain_for(0.7)
                keys("\r")
                wait_until(
                    lambda: b"setup-detail" in output,
                    "initial detail fixture was not applied",
                )

                server.set_phase("unconfirmed")
                keys("r")
                wait_until(
                    lambda: server.response_count("unconfirmed", "/health") >= 1,
                    "the open detail's workspace check failed",
                )
                drain_for(0.7)

                server.set_phase("recovery")
                keys("r")
                wait_until(
                    lambda: server.count("recovery", "/health") >= 1,
                    "recovery workspace check did not start",
                )
                # The refresh key has reached the health check. If the 503
                # did not revoke authority, it could read Fusion immediately.
                drain_for(1.0)
                self.assertEqual(server.count("recovery", LIST_PATH), 0)
                self.assertEqual(server.count("recovery", DETAIL_PATH), 0)
                server.release_recovery_health.set()
                wait_until(
                    lambda: (
                        server.count("recovery", LIST_PATH) >= 1
                        and server.count("recovery", DETAIL_PATH) >= 1
                    ),
                    "recovery started both reads",
                )
                server.release_recovery.set()
                wait_until(
                    lambda: b"recovery-list" in output and b"recovery-detail" in output,
                    "both recovery fixtures were not applied",
                )
                # A queued follow-up is emitted only after the blocked reads
                # settle. The cadence is 1000 seconds and the observer refuses.
                drain_for(1.0)
                self.assertEqual(
                    (
                        server.count("recovery", LIST_PATH),
                        server.count("recovery", DETAIL_PATH),
                    ),
                    (1, 1),
                    "one authority recovery must not queue duplicate Fusion GETs",
                )
                self.assertIsNone(process.poll())
            finally:
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
    FusionRecoveryTest.binary = os.path.abspath(sys.argv.pop(1))
    unittest.main()
