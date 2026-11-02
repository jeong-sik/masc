#!/usr/bin/env python3
"""Exercise task revalidation from an observer event without a polling tick."""

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


class TaskServer(FixtureServer):
    def __init__(self, base: str, *, hold_observer: bool) -> None:
        super().__init__(base)
        self.RequestHandlerClass = TaskHandler
        self.observer_requested = threading.Event()
        self.release_observer = threading.Event()
        if not hold_observer:
            self.release_observer.set()
        self.observer_ready = threading.Event()
        self.events: queue.Queue[tuple[int, str] | None] = queue.Queue()


class TaskHandler(FixtureHandler):
    def do_POST(self) -> None:
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        payload = b'{"jsonrpc":"2.0","id":1,"result":{}}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Mcp-Session-Id", "task-event-fixture")
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self) -> None:
        if urllib.parse.urlsplit(self.path).path != "/mcp":
            super().do_GET()
            return
        server = cast(TaskServer, self.server)
        expected = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        if expected.get("expected_base_path") != [
            os.path.realpath(server.base)
        ] or expected.get("expected_masc_root") != [
            os.path.realpath(server.base) + "/.masc"
        ]:
            self.respond(409, {"error": "workspace precondition failed"})
            return
        server.observer_requested.set()
        server.release_observer.wait()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("x-masc-sse-instance-id", "task-event-fixture")
        self.send_header("x-masc-sse-replay", "fresh")
        self.send_header("x-masc-workspace-read", "matched-v1")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.flush()
        server.observer_ready.set()
        while (event := server.events.get()) is not None:
            cursor, kind = event
            if kind == "loss":
                payload = {
                    "type": "agent_core:relay_subscription_loss",
                    "event_type": "relay_subscription_loss",
                    "ts_unix": 1.0,
                    "payload": {
                        "source_id": "fixture",
                        "sequence": 1,
                        "dropped_count": 1,
                    },
                }
            else:
                snapshot_payload: dict[str, object] = {
                    "execution_publication_epoch": "fixture",
                    "execution_publication_generation": cursor,
                    "execution_invalidated": kind != "full",
                }
                if kind == "full":
                    snapshot_payload.update(
                        {
                            "status": "ok",
                            "generated_at": "2026-01-01T00:00:00Z",
                            "tasks": [],
                            "keepers": [],
                        }
                    )
                payload = {
                    "type": "execution_snapshot",
                    "payload": snapshot_payload,
                    "ts_unix": 1.0,
                }
            data = json.dumps(payload).encode()
            try:
                self.wfile.write(f"id: {cursor}\ndata: ".encode() + data + b"\n\n")
                self.wfile.flush()
                server.record("observer-event-written")
            except (BrokenPipeError, ConnectionResetError):
                break
        self.close_connection = True


class TaskEventTest(unittest.TestCase):
    binary = ""

    def test_task_snapshot_reloads_local_work_without_polling(self) -> None:
        self.exercise_local_work(hold_observer=False)

    def test_observer_open_covers_the_initial_read_gap(self) -> None:
        self.exercise_local_work(hold_observer=True)

    def exercise_local_work(self, *, hold_observer: bool) -> None:
        with tempfile.TemporaryDirectory(prefix="masc-task-event-") as temp_base:
            base = os.path.realpath(temp_base)
            config = pathlib.Path(base, ".masc", "config")
            config.mkdir(parents=True)
            (config / "runtime.toml").write_text(
                '[tui]\nopening = "overview"\nhints_visible = false\n'
                "help_hint_shown = true\nreduce_motion = true\n",
                encoding="utf-8",
            )
            backlog = pathlib.Path(base, ".masc", "tasks", "backlog.json")
            backlog.parent.mkdir(parents=True)

            def write_task(
                title: str, version: int, *, preserve_stat: bool = False
            ) -> None:
                previous = backlog.stat() if preserve_stat else None
                body = {
                    "tasks": [
                        {
                            "id": "task-fixture",
                            "title": title,
                            "description": "fixture",
                            "status": "todo",
                            "created_at": "2026-01-01T00:00:00Z",
                        }
                    ],
                    "last_updated": "2026-01-01T00:00:00Z",
                    "version": version,
                }
                temporary = backlog.with_suffix(".tmp")
                temporary.write_text(json.dumps(body), encoding="utf-8")
                if previous is not None:
                    os.utime(temporary, ns=(previous.st_atime_ns, previous.st_mtime_ns))
                os.replace(temporary, backlog)
                if previous is not None:
                    current = backlog.stat()
                    self.assertEqual(previous.st_size, current.st_size)
                    self.assertEqual(previous.st_mtime_ns, current.st_mtime_ns)

            write_task("initial-task-marker", 1)
            server = TaskServer(base, hold_observer=hold_observer)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 35, 180, 0, 0))
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
            output = bytearray()

            def drain_for(seconds: float) -> None:
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    if select.select([master], [], [], 0.05)[0]:
                        try:
                            output.extend(os.read(master, 65536))
                        except OSError:
                            return

            def wait_until(
                predicate: Callable[[], bool], label: str, timeout: float = 20.0
            ) -> None:
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    if predicate():
                        return
                    if process.poll() is not None:
                        break
                    drain_for(0.05)
                self.fail(
                    f"{label}; exit={process.poll()}, requests={server.requests!r}, "
                    f"terminal tail={bytes(output[-4000:])!r}"
                )

            try:
                wait_until(
                    lambda: (
                        server.observer_requested.is_set()
                        and server.response_count("setup", "/health") >= 2
                    ),
                    "observer request and workspace admission were not ready",
                )
                drain_for(1.0)
                os.write(master, b"\t")
                wait_until(
                    lambda: server.count("setup", "/api/v1/dashboard/planning") >= 1,
                    "Work did not open",
                )
                os.write(master, b"t")
                wait_until(
                    lambda: b"initial-task-marker" in output,
                    "initial task was not drawn",
                )
                if hold_observer:
                    write_task("observer-open-recovery-marker", 2)
                    server.release_observer.set()
                    wait_until(
                        lambda: b"observer-open-recovery-marker" in output,
                        "observer open did not cover the initial read gap",
                        timeout=6.0,
                    )
                    return
                wait_until(server.observer_ready.is_set, "observer did not open")
                server.set_phase("changed")
                write_task("updated-task-marker-after-event", 2)
                server.events.put((1, "execution"))
                wait_until(
                    lambda: server.count("changed", "observer-event-written") == 1,
                    "task event was not sent",
                )
                wait_until(
                    lambda: b"updated-task-marker-after-event" in output,
                    "task event did not refresh the local work list",
                    timeout=6.0,
                )

                write_task("duplicate-must-not-trigger-marker", 3)
                server.events.put((1, "execution"))
                wait_until(
                    lambda: server.count("changed", "observer-event-written") == 2,
                    "duplicate event was not sent",
                )
                drain_for(1.0)
                self.assertNotIn(b"duplicate-must-not-trigger-marker", output)
                server.events.put((2, "execution"))
                wait_until(
                    lambda: b"duplicate-must-not-trigger-marker" in output,
                    "new cursor did not refresh local work",
                    timeout=6.0,
                )
                write_task("observer-loss-recovery-marker", 4)
                server.events.put((3, "loss"))
                wait_until(
                    lambda: b"observer-loss-recovery-marker" in output,
                    "observer source loss did not refresh local work",
                    timeout=6.0,
                )
                write_task("full-execution-snapshot-marker", 5)
                server.events.put((4, "full"))
                wait_until(
                    lambda: b"full-execution-snapshot-marker" in output,
                    "full execution snapshot did not refresh local work",
                    timeout=6.0,
                )
                write_task("FULL-execution-snapshot-marker", 6, preserve_stat=True)
                server.events.put((5, "execution"))
                wait_until(
                    lambda: b"FULL-execution-snapshot-marker" in output,
                    "same-stat task replacement stayed stale after an event",
                    timeout=6.0,
                )
                self.assertIsNone(process.poll())
            finally:
                server.release_observer.set()
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
        raise SystemExit("usage: test_tui_task_event.py /path/to/masc_tui.exe")
    TaskEventTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
