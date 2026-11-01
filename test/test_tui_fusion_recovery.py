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

    def __init__(self, base: str) -> None:
        super().__init__(("127.0.0.1", 0), FixtureHandler)
        self.base = base
        self.phase = "setup"
        self.requests: collections.Counter[tuple[str, str]] = collections.Counter()
        self.condition = threading.Condition()
        self.release_recovery = threading.Event()

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


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *_args: object) -> None:
        pass

    def respond(
        self, status: int, value: object, *, workspace_receipt: bool = False
    ) -> None:
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if workspace_receipt:
            self.send_header("x-masc-workspace-read", "matched-v1")
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self) -> None:
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.respond(503, {"error": "observer unavailable in fixture"})

    def do_GET(self) -> None:
        server = cast(FixtureServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        path = request.path
        phase = server.record(path)
        if path == "/health":
            if phase == "unconfirmed":
                self.respond(503, {"error": "health unavailable"})
            else:
                base = server.base
                self.respond(
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
                server.release_recovery.wait(timeout=10)
            run = dict(RUN)
            if phase == "recovery":
                run["keeper"] = "fresh-list" if path == LIST_PATH else "fresh-detail"
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
            self.respond(200, body, workspace_receipt=True)
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
            env = os.environ.copy()
            for name in ("MASC_HTTP_BASE_URL", "MASC_TOKEN", "MASC_HTTP_AUTH_STRICT"):
                env.pop(name, None)
            env["TERM"] = "xterm-256color"
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
            output = bytearray()

            def wait_until(
                predicate: Callable[[], bool], label: str, timeout: float = 12.0
            ) -> None:
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    if predicate():
                        return
                    if process.poll() is not None:
                        break
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
                    lambda: (
                        server.count("setup", "/health") >= 2
                        and (
                            b"HTTP [partial]" in output or b"HTTP [connected]" in output
                        )
                    ),
                    "initial workspace identity confirmed",
                )
                drain_for(1.0)
                keys(":")
                wait_until(
                    lambda: b"MASC Command palette" in output, "command palette opened"
                )
                keys("fusion")
                wait_until(lambda: b"go Fusion" in output, "Fusion command offered")
                fusion_output = len(output)
                keys("\r")
                wait_until(
                    lambda: b"MASC Fusion" in output[fusion_output:], "Fusion opened"
                )
                # If the initial probe's reading was withdrawn during startup,
                # explicitly confirm the fixture before selecting a run.
                keys("r")
                wait_until(
                    lambda: (
                        server.count("setup", LIST_PATH) >= 1 and b"1 run" in output
                    ),
                    "Fusion list ready",
                )
                keys("\r")
                wait_until(
                    lambda: (
                        server.count("setup", DETAIL_PATH) >= 1
                        and b"Evidence: pending" in output
                    ),
                    "Fusion detail ready",
                )

                server.set_phase("unconfirmed")
                old_output = len(output)
                keys("r")
                wait_until(
                    lambda: (
                        b"[workspace unconfirmed]" in output[old_output:]
                        and b"HTTP [refresh failed]" in output[old_output:]
                    ),
                    "the open detail lost workspace authority",
                )

                server.set_phase("recovery")
                keys("r")
                wait_until(
                    lambda: (
                        server.count("recovery", LIST_PATH) >= 1
                        and server.count("recovery", DETAIL_PATH) >= 1
                    ),
                    "recovery started both reads",
                )
                recovered_output = len(output)
                server.release_recovery.set()
                wait_until(
                    lambda: (
                        b"fresh-list" in output[recovered_output:]
                        and b"fresh-detail" in output[recovered_output:]
                    ),
                    "both recovery responses reached the open surface",
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
            finally:
                server.release_recovery.set()
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
