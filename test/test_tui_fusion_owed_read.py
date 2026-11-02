#!/usr/bin/env python3
"""A failed Fusion read is read again with a growing wait, and a successful
one is not read again until the server announces a change (RFC-0480 L2b).

The refresh cadence is pushed out of the test's lifetime, so every Fusion read
after the first comes from a retry.
"""

import fcntl
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

from test_tui_fusion_recovery import LIST_PATH, FixtureHandler, FixtureServer


WAIT_SECONDS = 25.0


class FusionServer(FixtureServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = FusionHandler
        self.observer_ready = threading.Event()
        self.release_observer = threading.Event()
        self.failures_left = 0
        self.list_times: list[float] = []


class FusionHandler(FixtureHandler):
    def do_POST(self) -> None:
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        payload = b'{"jsonrpc":"2.0","id":1,"result":{}}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Mcp-Session-Id", "fusion-fixture-session")
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self) -> None:
        server = cast(FusionServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == "/mcp":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("x-masc-sse-instance-id", "fusion-fixture-instance")
            self.send_header("x-masc-sse-replay", "fresh")
            self.send_header("x-masc-workspace-read", "matched-v1")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.flush()
            server.observer_ready.set()
            server.release_observer.wait(60)
            self.close_connection = True
            return
        if request.path == LIST_PATH:
            with server.condition:
                server.list_times.append(time.monotonic())
                fail = server.failures_left > 0
                if fail:
                    server.failures_left -= 1
            if fail:
                server.record(request.path)
                self.respond(503, {"error": "fusion runs unavailable"})
                return
        super().do_GET()


class FusionOwedReadTest(unittest.TestCase):
    binary = ""

    def test_failed_fusion_reads_are_read_again_with_growing_waits(self) -> None:
        with tempfile.TemporaryDirectory(prefix="masc-fusion-owed-") as temp_base:
            base = os.path.realpath(temp_base)
            config = pathlib.Path(base, ".masc", "config")
            config.mkdir(parents=True)
            (config / "runtime.toml").write_text(
                '[tui]\nopening = "overview"\nhints_visible = false\n'
                "help_hint_shown = true\nreduce_motion = true\n",
                encoding="utf-8",
            )
            server = FusionServer(base)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 35, 140, 0, 0))
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

            def drain_for(seconds: float) -> None:
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    if select.select([master], [], [], 0.05)[0]:
                        try:
                            os.read(master, 65536)
                        except OSError:
                            return

            def wait_until(predicate: Callable[[], bool], label: str) -> None:
                deadline = time.monotonic() + WAIT_SECONDS
                while time.monotonic() < deadline:
                    if predicate():
                        return
                    if process.poll() is not None:
                        break
                    drain_for(0.05)
                self.fail(f"{label}; exit={process.poll()}, requests={server.requests!r}")

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
                with server.condition:
                    server.failures_left = 2
                    server.list_times.clear()
                keys(":")
                drain_for(0.3)
                keys("fusion")
                drain_for(0.3)
                keys("\r")
                wait_until(
                    lambda: len(server.list_times) >= 3,
                    "two failed Fusion reads were not followed by a third",
                )
                drain_for(6.0)
                with server.condition:
                    times = list(server.list_times)
                # The third read succeeded, so nothing reads again.
                self.assertEqual(len(times), 3)
                first_wait = times[1] - times[0]
                second_wait = times[2] - times[1]
                self.assertGreater(first_wait, 1.0)
                self.assertGreater(second_wait, first_wait + 1.0)
            finally:
                server.release_observer.set()
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
        raise SystemExit("usage: test_tui_fusion_owed_read.py /path/to/masc_tui.exe")
    FusionOwedReadTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
