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
SCHEDULE_PATH = "/api/v1/dashboard/scheduled-automation"


class WaitingServer(FixtureServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = WaitingHandler
        self.observer_ready = threading.Event()
        self.observer_closed = threading.Event()
        self.release_observer_recovery = threading.Event()
        self.held_read_started = threading.Event()
        self.release_held_read = threading.Event()
        self.followup_started = threading.Event()
        self.release_followup = threading.Event()
        self.agenda_held_started = threading.Event()
        self.release_agenda_held = threading.Event()
        self.agenda_followup_started = threading.Event()
        self.release_agenda_followup = threading.Event()
        self.events: queue.Queue[tuple[int, str] | None] = queue.Queue()
        self.valid_admission = True
        self.invalid_schedule_query: dict[str, list[str]] | None = None
        self.observer_instance = "waiting-fixture-instance"


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
            phase = server.record("/mcp")
            if phase == "authority-recovery":
                server.release_observer_recovery.wait()
            if urllib.parse.parse_qs(request.query).get("sse_kind") != ["observer"]:
                self.respond(400, {"error": "observer stream required"})
                return
            expected = urllib.parse.parse_qs(request.query)
            if expected.get("expected_base_path") != [
                os.path.realpath(server.base)
            ] or expected.get("expected_masc_root") != [
                os.path.realpath(server.base) + "/.masc"
            ]:
                self.respond(409, {"error": "workspace precondition failed"})
                return
            instance = server.observer_instance
            requested_id = self.headers.get("Last-Event-ID")
            requested_instance = self.headers.get("x-masc-sse-instance-id")
            if requested_id is None:
                replay = "fresh"
            elif requested_instance == instance:
                replay = "resumed"
                server.record("observer-resume")
            elif requested_instance is None:
                replay = "reset-unscoped-cursor"
            else:
                replay = "reset-instance-changed"
                server.record("observer-instance-changed")
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("x-masc-sse-instance-id", instance)
            self.send_header("x-masc-sse-replay", replay)
            self.send_header("x-masc-workspace-read", "matched-v1")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.flush()
            server.observer_ready.set()
            if phase == "authority-recovery":
                server.record("observer-recovery-open")
            while (event := server.events.get()) is not None:
                cursor, keeper = event
                payload: dict[str, object]
                if keeper in ("__loss__", "__loss2__"):
                    payload = {
                        "type": "agent_core:relay_subscription_loss",
                        "event_type": "relay_subscription_loss",
                        "ts_unix": 1.0,
                        "payload": {
                            "source_id": "fixture",
                            "sequence": 2 if keeper == "__loss2__" else 1,
                            "dropped_count": 1,
                        },
                    }
                elif keeper == "__schedule__":
                    payload = {"type": "schedule_store_invalidated"}
                elif keeper == "__pending_confirm__":
                    payload = {"type": "operator_pending_confirm_invalidated"}
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
            server.observer_closed.set()
        elif request.path == SCHEDULE_PATH:
            phase = server.record(SCHEDULE_PATH)
            expected = urllib.parse.parse_qs(request.query)
            if "payload_target" in expected:
                server.record("schedule-target")
            if "schedule_id" in expected:
                server.record("schedule-detail")
            if expected.get("expected_base_path") != [server.base] or expected.get(
                "expected_masc_root"
            ) != [server.base + "/.masc"]:
                server.valid_admission = False
                server.invalid_schedule_query = expected
                if self.respond(409, {"error": "workspace precondition failed"}):
                    if "payload_target" in expected:
                        server.responded(phase, "schedule-target")
                    if "schedule_id" in expected:
                        server.responded(phase, "schedule-detail")
                return
            if "schedule_id" in expected:
                if self.respond(
                    200,
                    {"status": "found", "schedule_id": expected["schedule_id"][0], "wakes": []},
                    workspace_receipt=True,
                ):
                    server.responded(phase, "schedule-detail")
                return
            if phase == "agenda-held":
                server.agenda_held_started.set()
                server.release_agenda_held.wait()
            elif phase == "agenda-follow":
                server.agenda_followup_started.set()
                server.release_agenda_followup.wait()
            body = {
                "generated_at": "2026-11-02T00:00:00Z",
                "status": "ok",
                "payload_target_selector": expected.get("payload_target", [None])[0],
                "request_count": 0,
                "truncated": False,
                "fsm": {"next_due_at": None},
                "counts": None,
                "requests": [],
                "schedule_runner": {"status": "ok"},
            }
            if phase == "detail-open" and "payload_target" not in expected:
                actor = {"id": "fixture", "kind": "system"}
                body["request_count"] = 1
                body["requests"] = [
                    {
                        "schedule_instance_id": "fixture-instance",
                        "schedule_id": "fixture-schedule",
                        "status": "scheduled",
                        "source": "fixture",
                        "requested_by": actor,
                        "scheduled_by": actor,
                        "requested_at_iso": "2026-11-02T00:00:00Z",
                        "due_at_iso": "2026-11-03T00:00:00Z",
                        "recurrence_summary": "once",
                        "recurrence": {},
                        "payload_digest": "fixture",
                        "payload": {},
                        "payload_support": "supported",
                        "payload_target": "keeper:analyst",
                        "payload_keeper_name": "analyst",
                        "payload_summary": "fixture detail",
                        "runner_hold": None,
                    }
                ]
            if self.respond(200, body, workspace_receipt=True):
                server.responded(phase, SCHEDULE_PATH)
                if "payload_target" in expected:
                    server.responded(phase, "schedule-target")
        elif request.path == TURNS_PATH:
            phase = server.record(TURNS_PATH)
            expected = urllib.parse.parse_qs(request.query)
            if expected.get("expected_base_path") != [server.base] or expected.get(
                "expected_masc_root"
            ) != [server.base + "/.masc"]:
                server.valid_admission = False
                self.respond(409, {"error": "workspace precondition failed"})
                return
            if phase in ("held", "collision-held", "schedule-held"):
                server.held_read_started.set()
                server.release_held_read.wait()
            if phase in ("queued", "collision-follow", "schedule-follow"):
                server.followup_started.set()
                server.release_followup.wait()
            detail = {
                "held": "obsolete-waiting",
                "queued": "fresh-waiting",
                "collision-held": "collision-obsolete",
                "collision-follow": "collision-recovered",
                "collision-during": "collision-ignored",
                "schedule": "schedule-refreshed",
                "confirm": "confirm-refreshed",
                "confirm-recovered": "confirm-recovered",
                "schedule-held": "obsolete-schedule",
                "schedule-follow": "final-schedule",
                "reconnect": "reconnected-waiting",
                "restored-epoch": "replacement-waiting",
            }.get(phase, "old-waiting")
            beta_detail = {
                "held": "beta-updated",
                "queued": "beta-final",
                "schedule": "beta-schedule-refreshed",
            }.get(phase, "beta-before")

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
            if phase in ("collision-poll", "confirm-unavailable"):
                body["keepers"] = [
                    {"keeper_name": name, "status": "ok", "turn": None, "waiting": None}
                    for name in ("analyst", "beta", "gamma")
                ]
                body["waiting_errors"] = [
                    {
                        "keeper_name": None,
                        "source": (
                            "observation_unavailable"
                            if phase == "confirm-unavailable"
                            else "read_error"
                        ),
                        "waiting_on": "fixture",
                        "what": (
                            "운영자 확인 기한 관측 불가"
                            if phase == "confirm-unavailable"
                            else "unavailable"
                        ),
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
                        and server.response_count("setup", SCHEDULE_PATH) >= 1
                    ),
                    "observer and initial turns read were not ready",
                )
                drain_for(1.0)
                os.write(master, b"i")
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
                self.assertEqual(server.count("quiet", SCHEDULE_PATH), 0)
                server.set_phase("held")
                event_output_start = len(output)
                server.events.put((1, "analyst"))
                wait_until(
                    server.held_read_started.is_set, "first event did not start a read"
                )
                wait_until(
                    lambda: (
                        any(
                            marker in output[event_output_start:]
                            for marker in (
                                "대기 목록 갱신 중".encode(),
                                b"waiting refresh pending",
                                b"waiting inventory: refreshing",
                            )
                        )
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
                # While the read is held the row keeps its last observation and
                # draws nothing new for the event (#50974), so the screen has no
                # change to wait for. The event was sent above; what is left to
                # check is that the row neither flipped to the warning nor lost
                # the observation it kept.
                drain_for(1.0)
                self.assertFalse(
                    rendered_row_contains(
                        gamma_event_start, b"gamma", b"waiting unavailable"
                    )
                )
                self.assertTrue(latest_rendered_row_contains(b"gamma", b"gamma-before"))
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
                server.set_phase("schedule")
                schedule_output_start = len(output)
                server.events.put((6, "__schedule__"))
                wait_until(
                    lambda: server.response_count("schedule", TURNS_PATH) == 1,
                    "schedule invalidation did not re-read waiting inventory",
                )
                wait_until(
                    lambda: server.response_count("schedule", SCHEDULE_PATH) == 1,
                    "schedule invalidation did not refresh the agenda",
                )
                wait_until(
                    lambda: rendered_row_contains(
                        schedule_output_start, b"analyst", b"schedule-refreshed"
                    )
                    and rendered_row_contains(
                        schedule_output_start, b"beta", b"beta-schedule-refreshed"
                    ),
                    "schedule invalidation did not refresh every keeper",
                )
                drain_for(0.5)
                self.assertEqual(server.count("schedule", TURNS_PATH), 1)
                server.held_read_started.clear()
                server.release_held_read.clear()
                server.followup_started.clear()
                server.release_followup.clear()
                server.set_phase("schedule-held")
                schedule_race_start = len(output)
                server.events.put((7, "__schedule__"))
                wait_until(server.held_read_started.is_set, "schedule read did not start")
                server.set_phase("schedule-queued")
                server.events.put((8, "__schedule__"))
                wait_until(
                    lambda: server.count("schedule-queued", "observer-event-written") == 1,
                    "second schedule invalidation was not delivered",
                )
                self.assertEqual(server.count("schedule-queued", TURNS_PATH), 0)
                server.set_phase("schedule-follow")
                server.release_held_read.set()
                wait_until(server.followup_started.is_set, "schedule follow-up did not start")
                server.set_phase("schedule-after")
                server.release_followup.set()
                wait_until(
                    lambda: b"final-schedule" in output[schedule_race_start:],
                    "schedule follow-up did not refresh the waiting rows",
                )
                self.assertNotIn(b"obsolete-schedule", output[schedule_race_start:])
                self.assertEqual(server.count("schedule-after", TURNS_PATH), 0)
                server.set_phase("agenda-held")
                agenda_output_start = len(output)
                server.events.put((9, "__schedule__"))
                wait_until(server.agenda_held_started.is_set, "agenda read did not start")
                wait_until(
                    lambda: "일정 정보가 오래됐을 수 있음".encode() in output[agenda_output_start:],
                    "a held agenda read did not mark the empty snapshot as uncertain",
                )
                server.set_phase("agenda-queued")
                server.events.put((10, "__schedule__"))
                wait_until(
                    lambda: server.count("agenda-queued", "observer-event-written") == 1,
                    "second agenda invalidation was not delivered",
                )
                self.assertEqual(server.count("agenda-queued", SCHEDULE_PATH), 0)
                server.set_phase("agenda-follow")
                server.release_agenda_held.set()
                wait_until(server.agenda_followup_started.is_set, "agenda follow-up did not start")
                self.assertEqual(server.count("agenda-follow", SCHEDULE_PATH), 1)
                server.set_phase("agenda-after")
                server.release_agenda_followup.set()
                wait_until(
                    lambda: server.response_count("agenda-follow", SCHEDULE_PATH) == 1,
                    "agenda follow-up did not finish",
                )
                drain_for(0.5)
                self.assertEqual(server.count("agenda-after", SCHEDULE_PATH), 0)
                server.set_phase("confirm")
                confirm_output_start = len(output)
                server.events.put((11, "__pending_confirm__"))
                wait_until(
                    lambda: server.response_count("confirm", TURNS_PATH) == 1,
                    "pending confirmation invalidation did not re-read waiting inventory",
                )
                wait_until(
                    lambda: rendered_row_contains(
                        confirm_output_start, b"analyst", b"confirm-refreshed"
                    ),
                    "pending confirmation invalidation did not refresh the waiting row",
                )
                drain_for(0.5)
                self.assertEqual(server.count("confirm", SCHEDULE_PATH), 0)
                server.set_phase("confirm-unavailable")
                confirm_failure_start = len(output)
                server.events.put((12, "__pending_confirm__"))
                wait_until(
                    lambda: (
                        server.response_count("confirm-unavailable", TURNS_PATH) == 1
                    ),
                    "confirmation observation failure did not trigger a read",
                )
                wait_until(
                    lambda: (
                        "운영자 확인 기한 관측 불가".encode()
                        in output[confirm_failure_start:]
                    ),
                    "confirmation observation failure was not displayed",
                )
                server.set_phase("confirm-recovered")
                confirm_recovery_start = len(output)
                server.events.put((13, "__pending_confirm__"))
                wait_until(
                    lambda: rendered_row_contains(
                        confirm_recovery_start, b"analyst", b"confirm-recovered"
                    ),
                    "confirmation observation recovery was not displayed",
                )
                # Keep the general refresh in flight: a loss signal must still
                # start its own schedule read before that refresh completes.
                server.set_phase("recovery")
                os.write(master, b"r")
                wait_until(
                    lambda: server.count("recovery", "/health") >= 1,
                    "general refresh was not held in flight",
                )
                wait_until(
                    lambda: server.response_count("recovery", SCHEDULE_PATH) >= 1,
                    "the general refresh's schedule read did not finish",
                )
                server.set_phase("loss-inflight")
                server.events.put((14, "__loss2__"))
                wait_until(
                    lambda: server.response_count("loss-inflight", SCHEDULE_PATH) == 1,
                    "source loss did not independently revalidate the agenda",
                )
                self.assertEqual(server.response_count("recovery", "/health"), 0)
                server.release_recovery_health.set()
                wait_until(
                    lambda: server.response_count("recovery", "/health") >= 1,
                    "held general refresh did not finish",
                )
                drain_for(0.5)
                server.set_phase("reconnect")
                reconnect_output_start = len(output)
                server.events.put(None)
                wait_until(
                    lambda: server.count("reconnect", "/mcp") == 1,
                    "observer did not reconnect after the stream closed",
                )
                wait_until(
                    lambda: server.count("reconnect", "observer-resume") == 1,
                    "observer did not resume with its scoped cursor",
                )
                wait_until(
                    lambda: server.response_count("reconnect", TURNS_PATH) == 1,
                    "reconnected observer did not revalidate waiting inventory",
                )
                wait_until(
                    lambda: server.response_count("reconnect", SCHEDULE_PATH) == 1,
                    "reconnected observer did not revalidate the agenda",
                )
                wait_until(
                    lambda: rendered_row_contains(
                        reconnect_output_start, b"analyst", b"reconnected-waiting"
                    ),
                    "reconnected observer did not refresh the waiting row",
                )
                # A failed identity check suspends the stream and its reads.
                # Keep the next stream closed so authority recovery must start
                # the agenda read independently of Observer_opened or a tick.
                server.set_phase("unconfirmed")
                unconfirmed_output_start = len(output)
                os.write(master, b"r")
                wait_until(
                    lambda: server.response_count("unconfirmed", "/health") >= 1,
                    "workspace identity did not become unconfirmed",
                )
                wait_until(
                    lambda: "일정 정보가 오래됐을 수 있음".encode()
                    in output[unconfirmed_output_start:],
                    "suspending the observer did not mark the agenda uncertain",
                )
                server.observer_closed.clear()
                server.events.put(None)
                wait_until(server.observer_closed.is_set, "old observer did not close")
                server.set_phase("authority-recovery")
                os.write(master, b"r")
                wait_until(
                    lambda: server.response_count("authority-recovery", SCHEDULE_PATH) >= 1,
                    "authority recovery did not re-read the agenda",
                )
                self.assertEqual(server.count("authority-recovery", "observer-recovery-open"), 0)
                server.release_observer_recovery.set()
                wait_until(
                    lambda: server.count("authority-recovery", "observer-recovery-open") == 1,
                    "observer did not reopen after authority recovery",
                )
                server.set_phase("target-open")
                os.write(master, b"c")
                wait_until(
                    lambda: server.response_count("target-open", "schedule-target") >= 1,
                    "Keeper chat did not request its schedule page",
                )
                self.assertIsNone(server.invalid_schedule_query)
                server.set_phase("detail-open")
                os.write(master, b"\x1b")
                drain_for(0.3)
                os.write(master, b":")
                drain_for(0.3)
                os.write(master, b"schedules\r")
                wait_until(
                    lambda: b"fixture-schedule" in output,
                    "schedule fixture row was not displayed",
                )
                os.write(master, b"\r")
                wait_until(
                    lambda: server.response_count("detail-open", "schedule-detail") >= 1,
                    "opening a schedule did not request its wake history",
                )
                self.assertIsNone(server.invalid_schedule_query)
                self.assertTrue(server.valid_admission)
                self.assertIsNone(process.poll())
            finally:
                server.release_held_read.set()
                server.release_followup.set()
                server.release_agenda_held.set()
                server.release_agenda_followup.set()
                server.release_observer_recovery.set()
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
