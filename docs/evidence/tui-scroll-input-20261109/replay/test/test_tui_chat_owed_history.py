#!/usr/bin/env python3
"""The open chat reads its history once more when the server announced a
change it may have missed, and again after a failed read (RFC-0480 §3.1).

The refresh cadence is pushed out of the test's lifetime, so every history
read after the first comes from an announced change or a failed read.
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
WAIT_SECONDS = 25.0


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


class ChatServer(FixtureServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = ChatHandler
        self.observer_ready = threading.Event()
        self.hold_history = threading.Event()
        self.history_held = threading.Event()
        self.release_history = threading.Event()
        self.failures_left = 0
        self.history_times: list[float] = []
        self.events = ObserverEvents()
        self.observer_connections = 0
        self.observer_event_id = 0
        self.observer_restart_on_resume = True
        self.observer_gap_on_resume = False


class ChatHandler(FixtureHandler):
    def do_POST(self) -> None:
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        payload = b'{"jsonrpc":"2.0","id":1,"result":{}}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Mcp-Session-Id", "chat-fixture-session")
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def observer_event_label(self) -> str:
        return "observer-event-written"

    def observe(self, server: ChatServer) -> None:
        with server.condition:
            server.observer_connections += 1
        resuming = self.headers.get("Last-Event-ID") is not None
        restarted = resuming and server.observer_restart_on_resume
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header(
            "x-masc-sse-instance-id",
            "chat-fixture-successor" if restarted else "chat-fixture-instance",
        )
        replay = (
            "reset-instance-changed"
            if restarted
            else "resumed-after-gap"
            if resuming and server.observer_gap_on_resume
            else "resumed"
            if resuming
            else "fresh"
        )
        self.send_header("x-masc-sse-replay", replay)
        if replay == "resumed-after-gap":
            missed_through = int(self.headers["Last-Event-ID"]) + 1
            self.send_header("x-masc-sse-replay-missed-through", str(missed_through))
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
                server.observer_event_id += 1
                cursor = server.observer_event_id
            try:
                self.wfile.write(
                    f"id: {cursor}\ndata: ".encode() + json.dumps(event).encode() + b"\n\n"
                )
                self.wfile.flush()
                server.record(self.observer_event_label())
            except (BrokenPipeError, ConnectionResetError):
                break
        self.close_connection = True
        server.events.unsubscribe(subscription)

    def do_GET(self) -> None:
        server = cast(ChatServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == "/mcp":
            if urllib.parse.parse_qs(request.query).get("sse_kind") != ["observer"]:
                self.respond(400, {"error": "observer stream required"})
                return
            self.observe(server)
        elif request.path == HISTORY_PATH:
            phase = server.record(request.path)
            with server.condition:
                server.history_times.append(time.monotonic())
                fail = server.failures_left > 0
                if fail:
                    server.failures_left -= 1
            if server.hold_history.is_set():
                server.hold_history.clear()
                server.history_held.set()
                server.release_history.wait()
            if fail:
                sent = self.respond(503, {"error": "history unavailable"})
            else:
                sent = self.respond(200, [])
            if sent:
                server.responded(phase, request.path)
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


def appended() -> dict[str, object]:
    return {
        "type": "keeper_chat_appended",
        "name": "analyst",
        "connector": "dashboard",
        "ts_unix": 1.0,
    }


class ChatOwedHistoryTest(unittest.TestCase):
    binary = ""

    def run_chat(
        self,
        scenario: Callable[[ChatServer, Callable[..., None]], None],
        refresh_seconds: float = 1000.0,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="masc-chat-owed-") as temp_base:
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
            server = ChatServer(base)
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

            def drain_for(seconds: float) -> None:
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    if select.select([master], [], [], 0.05)[0]:
                        try:
                            chunk = os.read(master, 65536)
                            if transcript:
                                transcript.write(chunk)
                                transcript.flush()
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

            def step(action: str, *args: object) -> None:
                if action == "wait":
                    predicate, label = args
                    wait_until(cast(Callable[[], bool], predicate), cast(str, label))
                elif action == "drain":
                    drain_for(cast(float, args[0]))
                elif action == "keys":
                    keys(cast(str, args[0]))
                elif action == "sequence":
                    # One write, so an escape sequence reaches the reader whole.
                    os.write(master, cast(str, args[0]).encode())
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
                scenario(server, step)
            finally:
                server.release_history.set()
                server.events.put(None)
                server.release_recovery.set()
                server.release_recovery_health.set()
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

    def test_a_turn_appended_during_a_read_is_read_after_it(self) -> None:
        def scenario(server: ChatServer, step: Callable[..., None]) -> None:
            server.set_phase("open")
            server.hold_history.set()
            step("keys", "c")
            step("wait", server.history_held.is_set, "chat history did not start")
            server.set_phase("appended")
            server.events.put(appended())
            server.events.put(appended())
            step(
                "wait",
                lambda: server.count("appended", "observer-event-written") == 2,
                "appended events were not sent",
            )
            step("drain", 0.8)
            self.assertEqual(server.count("appended", HISTORY_PATH), 0)
            server.release_history.set()
            step(
                "wait",
                lambda: server.response_count("appended", HISTORY_PATH) == 1,
                "appended turns did not cause one history read after the held one",
            )
            step("drain", 1.0)
            self.assertEqual(server.count("appended", HISTORY_PATH), 1)

        self.run_chat(scenario)

    def test_failed_history_reads_are_read_again_with_growing_waits(self) -> None:
        def scenario(server: ChatServer, step: Callable[..., None]) -> None:
            server.set_phase("open")
            with server.condition:
                server.failures_left = 2
                server.history_times.clear()
            step("keys", "c")
            step(
                "wait",
                lambda: len(server.history_times) >= 3,
                "two failed history reads were not followed by a third",
            )
            step("drain", 6.0)
            with server.condition:
                times = list(server.history_times)
            # The third read succeeded, so nothing reads again.
            self.assertEqual(len(times), 3)
            first_wait = times[1] - times[0]
            second_wait = times[2] - times[1]
            self.assertGreater(first_wait, 1.0)
            self.assertGreater(second_wait, first_wait + 1.0)

        self.run_chat(scenario)

    def test_a_reopened_feed_reads_the_open_chat_again(self) -> None:
        def scenario(server: ChatServer, step: Callable[..., None]) -> None:
            server.set_phase("open")
            step("keys", "c")
            step(
                "wait",
                lambda: server.response_count("open", HISTORY_PATH) == 1,
                "chat history did not load",
            )
            step("drain", 0.5)
            server.set_phase("reopen")
            server.events.put("close")
            step(
                "wait",
                lambda: server.observer_connections >= 2,
                "the observer feed did not reconnect",
            )
            step(
                "wait",
                lambda: server.response_count("reopen", HISTORY_PATH) >= 1,
                "the reopened feed did not read the open chat again",
            )

        self.run_chat(scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_chat_owed_history.py /path/to/masc_tui.exe")
    ChatOwedHistoryTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
