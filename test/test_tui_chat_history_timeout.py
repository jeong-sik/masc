#!/usr/bin/env python3
"""A chat history read that only ends in the client's own timeout must not
take the TUI down: the pane keeps what it has, shows the warning line with
the scheduled retry, and the owed read retries after its backoff (RFC-0480
§3.1, task-3646).

The fixture holds every history request without answering, so the read can
only end when bin/masc_tui_http.ml's request timeout fires.
"""

import fcntl
import json
import os
import pathlib
import pty
import queue
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

from test_tui_fusion_recovery import FixtureHandler, FixtureServer


HISTORY_PATH = "/api/v1/keepers/analyst/chat/history"
WAIT_SECONDS = 40.0


class ObserverEvents:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.current: queue.Queue[dict[str, object] | str | None] | None = None
        self.closed = False

    def subscribe(self) -> queue.Queue[dict[str, object] | str | None]:
        subscription: queue.Queue[dict[str, object] | str | None] = queue.Queue()
        with self.lock:
            if self.current is not None:
                self.current.put("close")
            self.current = subscription
            if self.closed:
                subscription.put(None)
        return subscription

    def unsubscribe(self, subscription: queue.Queue[dict[str, object] | str | None]) -> None:
        with self.lock:
            if self.current is subscription:
                self.current = None

    def put(self, event: dict[str, object] | str | None) -> None:
        with self.lock:
            subscription = self.current
            if event is None:
                self.closed = True
            elif event == "close" and subscription is not None:
                self.current = None
            if subscription is not None:
                subscription.put(event)


class HistoryTimeoutServer(FixtureServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = HistoryTimeoutHandler
        self.observer_ready = threading.Event()
        self.history_held = threading.Event()
        self.history_times: list[float] = []
        self.history_holds: list[threading.Event] = []
        self.stopping = threading.Event()
        self.events = ObserverEvents()


class HistoryTimeoutHandler(FixtureHandler):
    def do_POST(self) -> None:
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        payload = b'{"jsonrpc":"2.0","id":1,"result":{}}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Mcp-Session-Id", "history-timeout-fixture-session")
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def observe(self, server: HistoryTimeoutServer) -> None:
        with server.condition:
            pass
        resuming = self.headers.get("Last-Event-ID") is not None
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("x-masc-sse-instance-id", "history-timeout-fixture-instance")
        replay = "resumed" if resuming else "fresh"
        self.send_header("x-masc-sse-replay", replay)
        self.send_header("x-masc-workspace-read", "matched-v1")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.flush()
        subscription = server.events.subscribe()
        server.observer_ready.set()
        while True:
            event = subscription.get()
            if event is None or event == "close":
                break
            with server.condition:
                server.observer_event_id = getattr(server, "observer_event_id", 0) + 1
                cursor = server.observer_event_id
            try:
                self.wfile.write(
                    f"id: {cursor}\ndata: ".encode() + json.dumps(event).encode() + b"\n\n"
                )
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                break
        self.close_connection = True
        server.events.unsubscribe(subscription)

    def do_GET(self) -> None:
        server = cast(HistoryTimeoutServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == "/mcp":
            if urllib.parse.parse_qs(request.query).get("sse_kind") != ["observer"]:
                self.respond(400, {"error": "observer stream required"})
                return
            self.observe(server)
        elif request.path == HISTORY_PATH:
            server.record(request.path)
            with server.condition:
                server.history_times.append(time.monotonic())
                release = threading.Event()
                server.history_holds.append(release)
            server.history_held.set()
            # Hold the request past the client's request timeout: the read can
            # only end as the client's own failure, never as a server answer.
            while not release.is_set() and not server.stopping.is_set():
                if release.wait(0.1):
                    break
            self.close_connection = True
        elif request.path == HISTORY_PATH + "/page":
            self.respond(
                200,
                {
                    "schema": "masc.keeper_chat_history.page.v2",
                    "messages": [],
                    "has_more": False,
                    "next_cursor": None,
                },
            )
        elif request.path == "/api/v1/keepers/analyst/memory-journal":
            self.respond(200, {"entries": []})
        else:
            super().do_GET()


class HistoryTimeoutTest(unittest.TestCase):
    binary = ""

    def run_chat(
        self,
        scenario: Callable[
            [HistoryTimeoutServer, Callable[..., None], subprocess.Popen, bytearray],
            None,
        ],
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="masc-history-timeout-") as temp_base:
            base = os.path.realpath(temp_base)
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
            server = HistoryTimeoutServer(base)
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
            transcript_path = os.environ.get("MASC_TUI_TEST_TRANSCRIPT")
            transcript = open(transcript_path, "wb") if transcript_path else None
            output = bytearray()

            def drain_for(seconds: float) -> None:
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    if select.select([master], [], [], 0.05)[0]:
                        try:
                            chunk = os.read(master, 65536)
                            if transcript:
                                transcript.write(chunk)
                                transcript.flush()
                            output.extend(chunk)
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
                self.fail(
                    f"{label}; exit={process.poll()}, requests={server.requests!r}, "
                    f"terminal tail={bytes(output[-3000:])!r}"
                )

            def keys(text: str) -> None:
                for key in text.encode():
                    os.write(master, bytes([key]))
                    time.sleep(0.03)

            def step(action: str, *args: object) -> None:
                if action == "wait":
                    predicate, label = args
                    wait_until(cast(Callable[[], bool], predicate), cast(str, label))
                elif action == "drain":
                    drain_for(cast(float, args[0]))
                elif action == "keys":
                    keys(cast(str, args[0]))
                else:
                    raise AssertionError(action)

            try:
                wait_until(
                    lambda: (
                        server.response_count("setup", "/health") >= 2
                        and server.observer_ready.is_set()
                    ),
                    "workspace and observer were not ready",
                )
                drain_for(1.0)
                keys("\t\t")
                drain_for(0.3)
                keys("r")
                drain_for(1.0)
                scenario(server, step, process, output)
            finally:
                server.stopping.set()
                with server.condition:
                    for release in server.history_holds:
                        release.set()
                server.events.put(None)
                if process.poll() is None:
                    process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                if transcript:
                    transcript.close()
                os.close(master)
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)

    def test_a_timed_out_history_read_keeps_the_tui_alive_and_retries(self) -> None:
        def scenario(
            server: HistoryTimeoutServer,
            step: Callable[..., None],
            process: subprocess.Popen,
            output: bytearray,
        ) -> None:
            server.set_phase("open")
            step("keys", "c")
            step(
                "wait",
                lambda: server.history_held.is_set,
                "chat history did not start",
            )
            # The held read cannot answer: the client gives up at its request
            # timeout (10s), and the owed read must schedule a retry instead of
            # taking the pane or the process down.
            step(
                "wait",
                lambda: len(server.history_times) >= 2,
                "the timed-out history read was not retried",
            )
            self.assertIsNone(
                process.poll(), "the TUI died during the history timeout"
            )
            step("drain", 1.0)
            rendered = bytes(output)
            self.assertIn("대화 기록 조회 실패".encode(), rendered)
            self.assertIn("재시도 예정".encode(), rendered)

        self.run_chat(scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_chat_history_timeout.py /path/to/masc_tui.exe")
    HistoryTimeoutTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
