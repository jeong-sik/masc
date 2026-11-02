#!/usr/bin/env python3
"""Exercise waiting-inventory SSE revalidation against a local TUI peer."""

import fcntl
import json
import os
import pathlib
import pty
import queue
import re
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


TURNS_PATH = "/api/v1/keepers/turns"


class WaitingServer(FixtureServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = WaitingHandler
        self.observer_ready = threading.Event()
        self.held_read_started = threading.Event()
        self.release_held_read = threading.Event()
        self.followup_started = threading.Event()
        self.release_followup = threading.Event()
        self.events: queue.Queue[tuple[int, str] | None] = queue.Queue()
        self.valid_admission = True


class WaitingHandler(FixtureHandler):
    def do_POST(self) -> None:
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        payload = b'{"jsonrpc":"2.0","id":1,"result":{}}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Mcp-Session-Id", "waiting-fixture-session")
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self) -> None:
        server = cast(WaitingServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == "/mcp":
            if urllib.parse.parse_qs(request.query).get("sse_kind") != ["observer"]:
                self.respond(400, {"error": "observer stream required"})
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("x-masc-sse-instance-id", "waiting-fixture-instance")
            self.send_header("x-masc-sse-replay", "fresh")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.flush()
            server.observer_ready.set()
            while (event := server.events.get()) is not None:
                cursor, keeper = event
                payload: dict[str, object]
                if keeper == "__loss__":
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
                    payload = {
                        "type": "keeper_waiting_inventory_changed",
                        "keeper_name": keeper,
                        "queue_kind": (
                            "approval_count" if keeper == "analyst" else "event_queue"
                        ),
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
        elif request.path == TURNS_PATH:
            phase = server.record(TURNS_PATH)
            expected = urllib.parse.parse_qs(request.query)
            if expected.get("expected_base_path") != [server.base] or expected.get(
                "expected_masc_root"
            ) != [server.base + "/.masc"]:
                server.valid_admission = False
                self.respond(409, {"error": "workspace precondition failed"})
                return
            if phase in ("held", "collision-held"):
                server.held_read_started.set()
                server.release_held_read.wait()
            if phase in ("queued", "collision-follow"):
                server.followup_started.set()
                server.release_followup.wait()
            detail = {
                "held": "obsolete-waiting",
                "queued": "fresh-waiting",
                "collision-held": "collision-obsolete",
                "collision-follow": "collision-recovered",
                "collision-during": "collision-ignored",
            }.get(phase, "old-waiting")
            beta_detail = {"held": "beta-updated", "queued": "beta-final"}.get(
                phase, "beta-before"
            )

            def keeper_row(name: str, text: str) -> dict[str, object]:
                return {
                    "keeper_name": name,
                    "status": "ok",
                    "turn": None,
                    "waiting": {
                        "keeper_name": name,
                        "state": "waiting",
                        "waiting_count": 1,
                        "since": None,
                        "due_at": None,
                        "waiting_on": [
                            {
                                "source": "event_queue_pending",
                                "waiting_on": "fixture",
                                "what": text,
                                "wake_producer": "keeper_owner_actor",
                                "since": None,
                                "due_at": None,
                                "next_action": "wake",
                            }
                        ],
                    },
                }

            beta = keeper_row("beta", beta_detail)
            if phase in ("duplicate", "collision-during"):
                beta["turn"] = {
                    "lane": "autonomous",
                    "started_at_unix": 1.0,
                    "interrupt_token": "fixture-token",
                    "turn_ref": None,
                    "preview": None,
                }
            body: dict[str, object] = {
                "schema": "masc.keeper_turns.v1",
                "keepers": [
                    keeper_row("analyst", detail),
                    beta,
                    keeper_row("gamma", "gamma-before"),
                ],
                "waiting_errors": [],
            }
            if phase == "collision-poll":
                body["keepers"] = [
                    {"keeper_name": name, "status": "ok", "turn": None, "waiting": None}
                    for name in ("analyst", "beta", "gamma")
                ]
                body["waiting_errors"] = [
                    {
                        "keeper_name": None,
                        "source": "read_error",
                        "waiting_on": "fixture",
                        "what": "unavailable",
                        "wake_producer": "read_model_reader",
                        "since": None,
                        "due_at": None,
                        "next_action": "retry",
                    }
                ]
            if self.respond(200, body, workspace_receipt=True):
                server.responded(phase, TURNS_PATH)
        else:
            super().do_GET()


class WaitingEventTest(unittest.TestCase):
    binary = ""

    def test_changes_while_reading_coalesce_without_cadence(self) -> None:
        with tempfile.TemporaryDirectory(prefix="masc-waiting-event-") as temp_base:
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
            (keepers / "beta.toml").write_text(
                '[keeper]\ninstructions = "Fixture"\n', encoding="utf-8"
            )
            (keepers / "gamma.toml").write_text(
                '[keeper]\ninstructions = "Fixture"\n', encoding="utf-8"
            )
            server = WaitingServer(base)
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

            def wait_until(predicate: Callable[[], bool], label: str) -> None:
                deadline = time.monotonic() + 25.0
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

            def rendered_row_contains(start: int, name: bytes, value: bytes) -> bool:
                raw = bytes(output[start:])
                raw = re.sub(rb"\x1b\[[0-9;]*H", b"\n", raw)
                raw = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", raw)
                return any(name in line and value in line for line in raw.splitlines())

            def latest_rendered_row_contains(name: bytes, value: bytes) -> bool:
                raw = re.sub(rb"\x1b\[[0-9;]*H", b"\n", bytes(output))
                raw = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", raw)
                rows = [line for line in raw.splitlines() if name in line]
                return bool(rows) and value in rows[-1]

            try:
                wait_until(
                    lambda: (
                        server.observer_ready.is_set()
                        and server.response_count("setup", "/health") >= 2
                        and server.response_count("setup", TURNS_PATH) >= 1
                    ),
                    "observer and initial turns read were not ready",
                )
                drain_for(1.0)
                os.write(master, b"i")
                wait_until(
                    lambda: b"MASC Keepers" in output, "keeper list was not opened"
                )
                wait_until(
                    lambda: b"old-waiting" in output,
                    "initial waiting row was not drawn",
                )
                wait_until(
                    lambda: latest_rendered_row_contains(b"gamma", b"gamma-before"),
                    "initial gamma row was not drawn",
                )
                gamma_baseline_start = len(output)
                drain_for(1.0)
                server.set_phase("quiet")
                drain_for(1.0)
                self.assertEqual(server.count("quiet", TURNS_PATH), 0)
                server.set_phase("held")
                event_output_start = len(output)
                server.events.put((1, "analyst"))
                wait_until(
                    server.held_read_started.is_set, "first event did not start a read"
                )
                wait_until(
                    lambda: (
                        b"waiting inventory: refreshing" in output[event_output_start:]
                    ),
                    "waiting refresh was not shown as pending",
                )
                server.set_phase("queued")
                server.events.put((2, "analyst"))
                wait_until(
                    lambda: server.count("queued", "observer-event-written") == 1,
                    "the second event was not sent",
                )
                self.assertTrue(latest_rendered_row_contains(b"gamma", b"gamma-before"))
                self.assertFalse(
                    rendered_row_contains(
                        gamma_baseline_start, b"gamma", b"waiting unavailable"
                    )
                )
                gamma_event_start = len(output)
                server.events.put((3, "gamma"))
                wait_until(
                    lambda: server.count("queued", "observer-event-written") == 2,
                    "queued events were not sent",
                )
                wait_until(
                    lambda: rendered_row_contains(
                        gamma_event_start, b"gamma", b"waiting unavailable"
                    ),
                    "the TUI did not apply the later gamma event",
                )
                self.assertEqual(server.count("queued", TURNS_PATH), 0)
                server.release_held_read.set()
                wait_until(
                    server.followup_started.is_set, "follow-up read did not start"
                )
                wait_until(
                    lambda: b"beta-updated" in output[event_output_start:],
                    "the unaffected keeper was not updated while the follow-up was held",
                )
                self.assertNotIn(b"obsolete-waiting", output[event_output_start:])
                server.release_followup.set()
                wait_until(
                    lambda: server.response_count("queued", TURNS_PATH) == 1,
                    "changes during the held read did not trigger a follow-up",
                )
                wait_until(
                    lambda: b"fresh-waiting" in output[event_output_start:],
                    "the follow-up waiting row was not drawn",
                )
                drain_for(1.0)
                self.assertNotIn(b"obsolete-waiting", output[event_output_start:])
                self.assertEqual(server.count("held", TURNS_PATH), 1)
                self.assertEqual(server.count("queued", TURNS_PATH), 1)
                server.set_phase("duplicate")
                duplicate_output_start = len(output)
                server.events.put((3, "gamma"))
                server.events.put((4, "__loss__"))
                wait_until(
                    lambda: b"[events lost]" in output[duplicate_output_start:],
                    "the event after the duplicate was not applied",
                )
                self.assertEqual(server.count("duplicate", "observer-event-written"), 2)
                wait_until(
                    lambda: server.response_count("duplicate", TURNS_PATH) == 1,
                    "loss-sentinel refresh did not complete",
                )
                wait_until(
                    lambda: rendered_row_contains(
                        duplicate_output_start, b"beta", b"running"
                    ),
                    "the TUI did not apply the sentinel refresh",
                )
                drain_for(0.5)
                self.assertEqual(server.count("duplicate", TURNS_PATH), 1)
                server.held_read_started.clear()
                server.release_held_read.clear()
                server.followup_started.clear()
                server.release_followup.clear()
                server.set_phase("collision-held")
                collision_output_start = len(output)
                server.events.put((5, "analyst"))
                wait_until(
                    server.held_read_started.is_set,
                    "collision event read did not start",
                )
                server.set_phase("collision-poll")
                os.write(master, b"r")
                wait_until(
                    lambda: server.response_count("collision-poll", TURNS_PATH) == 1,
                    "manual turns read did not complete during the event read",
                )
                wait_until(
                    lambda: (
                        b"fleet waiting observation unavailable"
                        in output[collision_output_start:]
                    ),
                    "the partial poll was not shown",
                )
                server.set_phase("collision-follow")
                server.release_held_read.set()
                wait_until(
                    server.followup_started.is_set,
                    "collision reconciliation did not start",
                )
                server.set_phase("collision-during")
                poll_output_start = len(output)
                os.write(master, b"r")
                wait_until(
                    lambda: server.response_count("collision-during", TURNS_PATH) == 1,
                    "turns read did not continue during reconciliation",
                )
                wait_until(
                    lambda: rendered_row_contains(
                        poll_output_start, b"beta", b"running"
                    ),
                    "the TUI did not apply the turns part of the concurrent poll",
                )
                self.assertNotIn(b"collision-ignored", output[collision_output_start:])
                server.set_phase("collision-after")
                server.release_followup.set()
                wait_until(
                    lambda: b"collision-recovered" in output[collision_output_start:],
                    "exclusive reconciliation was not applied",
                )
                drain_for(1.0)
                self.assertNotIn(b"collision-obsolete", output[collision_output_start:])
                self.assertEqual(server.count("collision-after", TURNS_PATH), 0)
                self.assertTrue(server.valid_admission)
                self.assertIsNone(process.poll())
            finally:
                server.release_held_read.set()
                server.release_followup.set()
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
                os.close(master)
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_waiting_event.py /path/to/masc_tui.exe")
    WaitingEventTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
