"""A refresh pass after a failed /health waits, and each wait is longer
(RFC tui-one-screen-grammar §2, §10).

The fixture confirms the workspace, then answers 500 to every /health. Its
observer stream still confirms the workspace on each reconnect, so a TUI that
does not wait reads /health again at once, many times a second. The test
counts the /health requests the TUI sends and nothing it draws.
"""

from __future__ import annotations

import fcntl
import http.server
import json
import os
import pathlib
import pty
import select
import shutil
import socketserver
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import traceback
import unittest
import urllib.parse
from typing import cast


SESSION = "fixture-session"
INSTANCE = "fixture-instance"
WAIT_SECONDS = 25.0
# Long enough for the first wait (2 s) and the second (4 s) to pass.
FAILING_SECONDS = 9.0
# The two probes of one pass go out together; separate passes are further apart.
SAME_PASS_SECONDS = 0.5
# The first wait is 2 s; this leaves room for a slow host.
SHORTEST_WAIT_SECONDS = 1.5


class PaceServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    request_queue_size = 128

    def __init__(self, base: str) -> None:
        super().__init__(("127.0.0.1", 0), PaceHandler)
        self.base = os.path.realpath(base)
        self.condition = threading.Condition()
        self.failing_since: float | None = None
        self.failed_health: list[float] = []
        self.release = threading.Event()

    def failed_reads(self) -> list[float]:
        with self.condition:
            return list(self.failed_health)

    def handle_error(self, request: object, client_address: object) -> None:
        # The TUI drops streams and requests it no longer wants.
        del request, client_address
        if not isinstance(sys.exc_info()[1], ConnectionError):
            traceback.print_exc()


class PaceHandler(http.server.BaseHTTPRequestHandler):
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
        server = cast(PaceServer, self.server)
        split = urllib.parse.urlsplit(self.path)
        if split.path == "/health":
            with server.condition:
                failing = server.failing_since is not None
                if failing:
                    server.failed_health.append(time.monotonic())
                    server.condition.notify_all()
            if failing:
                self.respond(500, {"error": "fixture health failure"})
            else:
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
        if split.path != "/mcp":
            self.respond(200, {})
            return
        query = urllib.parse.parse_qs(split.query)
        if query.get("expected_base_path") != [server.base] or query.get(
            "expected_masc_root"
        ) != [server.base + "/.masc"]:
            self.respond(409, {"error": "workspace precondition failed"})
            return
        # The first stream opens only after a pass confirmed the workspace.
        # From then on /health fails, while every stream still attests it.
        with server.condition:
            if server.failing_since is None:
                server.failing_since = time.monotonic()
                server.condition.notify_all()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("x-masc-workspace-read", "matched-v1")
        self.send_header("x-masc-sse-instance-id", INSTANCE)
        self.send_header("x-masc-sse-replay", "fresh")
        self.send_header("x-masc-observer-identity", "v1")
        self.send_header("x-masc-observer-version", "fixture")
        self.send_header("x-masc-observer-binary-commit", "fixture")
        self.send_header("Connection", "close")
        self.end_headers()
        while not server.release.is_set():
            try:
                self.wfile.write(b": fixture\n\n")
                self.wfile.flush()
            except OSError:
                return
            server.release.wait(0.5)
        self.close_connection = True


def bursts(times: list[float]) -> list[list[float]]:
    """Reads closer than SAME_PASS_SECONDS to the one before form one burst."""
    found: list[list[float]] = []
    for at in times:
        if found and at - found[-1][-1] <= SAME_PASS_SECONDS:
            found[-1].append(at)
        else:
            found.append([at])
    return found


class RefreshPaceRequestsTest(unittest.TestCase):
    binary = ""

    def failed_health_reads(self) -> tuple[float, list[float]]:
        """When /health started failing and when each failed read arrived."""
        with tempfile.TemporaryDirectory(prefix="masc-refresh-pace-") as base:
            config = pathlib.Path(base, ".masc", "config")
            config.mkdir(parents=True)
            (config / "runtime.toml").write_text(
                '[tui]\nopening = "overview"\nhints_visible = false\n'
                "help_hint_shown = true\nreduce_motion = true\n",
                encoding="utf-8",
            )
            # A copy in a directory of its own has no server binary beside
            # it, so the TUI cannot start one when /health fails.
            tui_dir = pathlib.Path(base, "tui")
            tui_dir.mkdir()
            tui = tui_dir / "masc-tui"
            shutil.copy2(self.binary, tui)
            server = PaceServer(base)
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
                    [str(tui), "--base-path", base, "--port", str(server.server_port)],
                    stdin=slave,
                    stdout=slave,
                    stderr=slave,
                    env=env,
                    close_fds=True,
                )
                os.close(slave)
                slave = -1

                def drain_for(seconds: float) -> None:
                    assert process is not None
                    deadline = time.monotonic() + seconds
                    while time.monotonic() < deadline:
                        if process.poll() is not None:
                            self.fail(f"the TUI exited with {process.poll()}")
                        if select.select([master], [], [], 0.05)[0]:
                            try:
                                os.read(master, 65536)
                            except OSError:
                                self.fail("the terminal closed")

                deadline = time.monotonic() + WAIT_SECONDS
                while server.failing_since is None and time.monotonic() < deadline:
                    drain_for(0.1)
                failing_since = server.failing_since
                if failing_since is None:
                    self.fail("the TUI never confirmed the workspace and opened its stream")
                drain_for(FAILING_SECONDS)
                return failing_since, server.failed_reads()
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

    def test_passes_after_a_failed_health_wait_longer_each_time(self) -> None:
        failing_since, reads = self.failed_health_reads()
        found = bursts(reads)
        spans = [round(burst[-1] - burst[0], 2) for burst in found]
        # One pass sends its probes together. A burst that lasts longer is
        # passes going out one after another with no wait between them.
        for span in spans:
            self.assertLess(span, SAME_PASS_SECONDS, f"burst spans {spans}")
        starts = [burst[0] - failing_since for burst in found]
        waits = [later - earlier for earlier, later in zip(starts, starts[1:])]
        # The owed pass comes back by itself, twice within the window.
        self.assertGreaterEqual(len(starts), 3, f"pass starts {starts}")
        # No pass goes out before its wait.
        for wait in waits:
            self.assertGreaterEqual(wait, SHORTEST_WAIT_SECONDS, f"waits {waits}")
        # Each failure in a row waits longer than the one before.
        for earlier, later in zip(waits, waits[1:]):
            self.assertGreater(later, earlier, f"waits {waits}")


if __name__ == "__main__":
    RefreshPaceRequestsTest.binary = os.path.abspath(sys.argv.pop(1))
    unittest.main()
