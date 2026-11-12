#!/usr/bin/env python3
"""Exercise a same-path observer epoch change against an isolated TUI peer."""

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

from test_tui_waiting_event import TURNS_PATH, WaitingHandler, WaitingServer


class EpochServer(WaitingServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = EpochHandler
        self.preflight_started = threading.Event()
        self.release_preflight = threading.Event()
        self.replacement_health_started = threading.Event()
        self.release_replacement_health = threading.Event()


class EpochHandler(WaitingHandler):
    def handle(self) -> None:
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            # The TUI cancels an old request when its authority is retired.
            pass

    def do_POST(self) -> None:
        server = cast(EpochServer, self.server)
        if urllib.parse.urlsplit(self.path).path == "/api/v1/keepers/chat/stream":
            server.record("chat-post")
        super().do_POST()

    def do_GET(self) -> None:
        server = cast(EpochServer, self.server)
        phase: str | None = None
        if urllib.parse.urlsplit(self.path).path == "/health":
            with server.condition:
                if server.phase in ("preflight", "epoch-replacement"):
                    phase = server.record("/health")
        if phase is not None:
            if phase == "preflight":
                server.preflight_started.set()
                server.release_preflight.wait()
            else:
                server.replacement_health_started.set()
                server.release_replacement_health.wait()
            if self.respond(
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
            ):
                server.responded(phase, "/health")
            return
        super().do_GET()


class ObserverEpochTest(unittest.TestCase):
    binary = ""

    def test_same_path_epoch_change_retires_old_reads_and_revalidates(self) -> None:
        with tempfile.TemporaryDirectory(prefix="masc-observer-epoch-") as temporary:
            base = os.path.realpath(temporary)
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
            server = EpochServer(base)
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
                ],
                stdin=slave,
                stdout=slave,
                stderr=slave,
                cwd=base,
                close_fds=True,
                env={
                    "HOME": base,
                    "TMPDIR": base,
                    "PATH": os.defpath,
                    "TERM": "xterm-256color",
                    "LANG": "C.UTF-8",
                },
            )
            os.close(slave)
            output = bytearray()

            def drain() -> None:
                if select.select([master], [], [], 0.05)[0]:
                    try:
                        output.extend(os.read(master, 65536))
                    except OSError:
                        pass

            def wait_until(
                predicate: Callable[[], bool], label: str, timeout: float = 25.0
            ) -> None:
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    if predicate():
                        return
                    if process.poll() is not None:
                        break
                    drain()
                self.fail(
                    f"{label}; exit={process.poll()}, requests={server.requests!r}, terminal={bytes(output[-2500:])!r}"
                )

            try:
                wait_until(
                    lambda: (
                        server.observer_ready.is_set()
                        and server.response_count("setup", TURNS_PATH) >= 1
                    ),
                    "initial observer and inventory were not ready",
                )
                # The peer can answer before the TUI is ready to read input.
                deadline = time.monotonic() + 1.0
                while time.monotonic() < deadline:
                    drain()
                os.write(master, b"i")
                wait_until(
                    lambda: b"old-waiting" in output,
                    "initial waiting row was not drawn",
                )

                server.set_phase("held")
                server.events.put((1, "analyst"))
                wait_until(
                    server.held_read_started.is_set, "old-generation read did not start"
                )
                # Hold one input before its first POST and queue another behind
                # it. A workspace transition must not auto-send either one.
                os.write(master, b"c")
                wait_until(
                    lambda: server.response_count("held", "schedule-target") >= 1,
                    "keeper chat did not open",
                )
                for _ in range(10):
                    drain()
                server.set_phase("preflight")
                os.write(master, b"epoch-first-input\r")
                wait_until(
                    server.preflight_started.is_set, "input preflight did not start"
                )
                os.write(master, b"epoch-second-queued\r")
                wait_until(
                    lambda: (
                        b"Input retained locally" in output
                    ),
                    "second input was not retained behind the first",
                )
                self.assertEqual(server.count("preflight", "chat-post"), 0)
                server.observer_instance = "waiting-fixture-replacement"
                server.set_phase("epoch-replacement")
                epoch_output = len(output)
                server.events.put(None)
                wait_until(
                    lambda: (
                        server.count("epoch-replacement", "observer-instance-changed")
                        == 1
                    ),
                    "replacement observer did not report the different generation",
                )
                wait_until(
                    server.replacement_health_started.is_set,
                    "same-path observer generation change did not revalidate workspace authority",
                    timeout=8.0,
                )
                server.release_preflight.set()
                server.release_held_read.set()
                for _ in range(10):
                    drain()
                self.assertNotIn(b"obsolete-waiting", output[epoch_output:])

                server.set_phase("restored-epoch")
                server.release_replacement_health.set()
                wait_until(
                    lambda: server.response_count("epoch-replacement", "/health") >= 1,
                    "replacement health did not finish",
                )
                wait_until(
                    lambda: (
                        server.count("restored-epoch", "/mcp") >= 1
                        and b"epoch-second-queued" in output[epoch_output:]
                    ),
                    "the replacement observer or retained input did not recover",
                )
                os.write(master, b"\x1b")
                wait_until(
                    lambda: b"replacement-waiting" in output[epoch_output:],
                    "new generation did not recover its waiting inventory",
                )
                deadline = time.monotonic() + 1.0
                while time.monotonic() < deadline:
                    drain()
                self.assertEqual(server.count("epoch-replacement", "chat-post"), 0)
                self.assertEqual(server.count("restored-epoch", "chat-post"), 0)
                self.assertIsNone(process.poll())
            finally:
                server.release_preflight.set()
                server.release_held_read.set()
                server.release_replacement_health.set()
                server.events.put(None)
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
        raise SystemExit("usage: test_tui_observer_epoch.py /path/to/masc_tui.exe")
    ObserverEpochTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
