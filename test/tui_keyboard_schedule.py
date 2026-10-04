from __future__ import annotations

import base64
import hashlib
import json
import os
import subprocess
import threading
import zlib
from pathlib import Path

from tui_keyboard_harness import (
    CSI_RE,
    FRAME_END,
    FRAME_START,
    FULL_REDRAW,
    HttpFixtures,
    Interaction,
    copy_reference,
    overview_event_http_fixtures,
    palette_go,
    run_terminal_scenario,
    screen_row_of,
    screen_rows,
    screen_text,
    send_and_wait,
)

SCHEDULES_PATH = "/api/v1/dashboard/scheduled-automation"

# The schedule list's [schedule_runner]: the runner's status word, the one
# /health reports, and nothing else of that object. The TUI reads the word.
SCHEDULE_RUNNER_OK = {
    "schema": "masc.dashboard.scheduled_automation.schedule_runner.v1",
    "status": "ok",
}


def schedule_detail_http_fixtures() -> HttpFixtures:
    fixtures = overview_event_http_fixtures()
    fixtures[SCHEDULES_PATH] = (
        200,
        {
            "status": "ok",
            "schedule_store_read_error": None,
            "request_count": 1,
            "truncated": False,
            "fsm": {"next_due_at": "2026-08-25T10:30:00Z"},
            # The runner's status word rides the list once, the word /health
            # reports. The loader requires it: a row's runner_hold is only
            # current while this reads ok.
            "schedule_runner": SCHEDULE_RUNNER_OK,
            "requests": [
                {
                    "schedule_instance_id": "instance-proof-701",
                    "schedule_id": "schedule-proof-701",
                    "status": "running",
                    "source": "operator",
                    "requested_by": {
                        "id": "operator-701",
                        "kind": "human_operator",
                        "display_name": "Operator Proof",
                    },
                    "scheduled_by": {
                        "id": "keeper-701",
                        "kind": "automated_actor",
                        "display_name": None,
                    },
                    "requested_at_iso": "2026-08-25T09:00:00Z",
                    "due_at_iso": "2026-08-25T10:00:00Z",
                    "next_due_at_iso": "2026-08-25T10:30:00Z",
                    "expires_at_iso": "2026-08-26T10:00:00Z",
                    # The loader requires this beside the summary. It was
                    # missing until 2026-09-08: the scenario that reads this
                    # fixture sits behind the stall in the default keyboard
                    # lane (#34125), so nothing rejected it.
                    "recurrence": {"kind": "interval", "interval_sec": 1800},
                    "recurrence_summary": "every 30 minutes",
                    "payload_digest": "digest-proof-701",
                    "payload": {
                        "kind": "masc.keeper_wake",
                        "body": {
                            "keeper_name": "alpha",
                            "title": "detailed scheduled sweep",
                        },
                    },
                    "payload_kind": "keeper_wake",
                    "payload_support": "supported",
                    "payload_dispatch_tool": "keeper_wake",
                    "payload_target": "alpha",
                    "payload_summary": "Run the detailed scheduled sweep.",
                    "last_wake": {
                        "status": "succeeded",
                        "started_at_iso": "2026-08-25T09:30:00Z",
                        "error": None,
                    },
                    "keeper_queue_evidence": {
                        "projection_status": "matched_pending",
                        "pending_count": 2,
                    },
                    "keeper_reaction_evidence": {
                        "projection_status": "matched_consumed_ack",
                        "keeper_name": "alpha",
                        "stimulus_id": "schedule-stimulus-proof-701",
                        "post_id": "schedule-occurrence-proof-701",
                        "reaction_kind": "turn_started",
                        "stimulus_seen": True,
                        "turn_started_seen": True,
                        "event_queue_ack_seen": True,
                        "event_queue_cancelled_seen": False,
                        "quarantined_record_count": 0,
                        "stimulus_recorded_at_iso": "2026-08-25T09:30:10Z",
                        "turn_started_recorded_at_iso": "2026-08-25T09:30:20Z",
                        "event_queue_ack_recorded_at_iso": "2026-08-25T09:31:00Z",
                        "event_queue_cancelled_recorded_at_iso": None,
                        "latest_recorded_at_iso": "2026-08-25T09:31:00Z",
                        "reason": None,
                    },
                    # Always on the row, null when the runner holds nothing:
                    # the loader refuses a row without it.
                    "runner_hold": None,
                }
            ],
        },
    )
    fixtures[SCHEDULES_PATH + "?schedule_id=schedule-proof-701"] = (
        200,
        {"status": "found", "schedule_id": "schedule-proof-701",
         "wakes": [{"status": "succeeded", "started_at_iso": "2026-08-25T09:30:00Z",
                    "finished_at_iso": "2026-08-25T09:30:01Z", "error": None}],
         "wake_retention_per_schedule": 32},
    )
    return fixtures


def schedule_detail_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        # Wait for a loaded row, not for the title. The title is drawn the
        # moment the screen opens, while the list still reads
        # "HTTP [loading...]" and "(not loaded yet - press r)". Waiting on the
        # title let the checks below read that frame, and they failed on a
        # list that had not arrived yet (PR check runs 36250155607,
        # 36250173553, 36251291941). The reaction fact is contiguous in raw
        # terminal output. The row's "succeeded consumed_ack" crosses an ANSI
        # style boundary; require that full row text after stripping below.
        listing = palette_go(
            process, master_fd, output, b"go schedules", b"reaction:matched_consumed_ack"
        )
        listing_plain = CSI_RE.sub(b"", listing)
        for needle in (
            # The column names above the list. The row used to name one of
            # its six columns inside itself -- "wake:" on the word, a dot
            # before the delivery's -- and leave the other five unnamed.
            b"TARGET",
            b"WAKE",
            b"DELIVERY",
            b"RECURRENCE",
            # What became of the wake, on the row itself. The enqueue result
            # beside it is "succeeded" on a wake the queue cancelled forty
            # seconds later, so the list said nothing about delivery until
            # the cursor was moved onto the row. Both words are in the needle
            # because either alone also appears in the reaction line below the
            # list, which is the surface this is not testing.
            b"succeeded consumed_ack",
            # The list used to carry a dispatch chip beside these. #31562
            # dropped it because it only ever repeated the row's own status,
            # which the identity line above the delivery row already names.
            b"status:running",
            b"queue:matched_pending/2 pending",
            b"reaction:matched_consumed_ack",
        ):
            if needle not in listing_plain:
                raise AssertionError(
                    f"Schedule list omitted {needle!r}: {listing_plain!r}"
                )
        detail = send_and_wait(
            process, master_fd, output, b"\x1b[C", b"instance-proof-701"
        )
        plain = CSI_RE.sub(b"", detail)
        for needle in (
            b"masc://schedules/schedule-proof-701",
            b"masc://keepers/alpha",
            b"Dispatch",
            # The kind is a word beside the name, not the wire token.
            b"Operator Proof (human)",
            b"keeper_wake",
            b"digest-proof-701",
            b"PgUp/PgDn:page",
        ):
            if needle not in plain:
                raise AssertionError(f"Schedule detail omitted {needle!r}: {plain!r}")
        copy_reference(
            process,
            master_fd,
            output,
            b"masc://schedules/schedule-proof-701",
        )
        evidence = send_and_wait(
            process, master_fd, output, b"\x1b[6~", b"WAKES (1 retained"
        )
        evidence_plain = CSI_RE.sub(b"", evidence)
        for needle in (
            b"WAKES (1 retained, ceiling 32 per schedule)",
            b"DELIVERY EVIDENCE",
            b"pending=2",
            b"matched_consumed_ack",
        ):
            if needle not in evidence_plain:
                raise AssertionError(
                    f"Schedule wake/delivery page omitted {needle!r}: {evidence_plain!r}"
                )
        # A retained wake is a row of the same table as the fields around
        # it: its status is the label and its times start in the value
        # column. It used to be padded with its own literal width, which
        # put the times two cells left of the Reaction time below. The
        # frame positions rows with cursor moves rather than newlines, so
        # the column is read as the width of the label plus its gap.
        def label_span(label: bytes) -> int:
            at = evidence_plain.find(label + b" ")
            if at < 0:
                raise AssertionError(
                    f"Schedule wake/delivery page has no {label!r} row: {evidence_plain!r}"
                )
            rest = evidence_plain[at + len(label):]
            return len(label) + len(rest) - len(rest.lstrip(b" "))

        if label_span(b"succeeded") != label_span(b"Reaction"):
            raise AssertionError(
                "the retained wake's time does not start in the value column: "
                f"{label_span(b'succeeded')} vs {label_span(b'Reaction')}"
            )
        # Delivery identity and the work-result boundary follow the queue
        # summary. Read their page rather than treating one viewport as all
        # retained evidence; the operator can reach both with PgDn.
        result_page = send_and_wait(
            process, master_fd, output, b"\x1b[6~", b"Keeper Calls or Activity"
        )
        result_plain = CSI_RE.sub(b"", result_page)
        for needle in (
            b"Keeper evidence",
            b"masc://keepers/alpha",
            b"schedule-stimulus-proof-701",
            b"schedule-occurrence-proof-701",
            b"Turn started",
            b"2026-08-25T09:30:20Z",
            b"Turn finished",
            b"WORK RESULT",
            b"bounded by its start and finish rows",
            b"Keeper Calls or Activity",
        ):
            if needle not in result_plain:
                raise AssertionError(
                    f"Schedule turn/result page omitted {needle!r}: {result_plain!r}"
                )
        result_rows = screen_rows(result_page)
        if not any(b"Turn started" in row and b"2026-08-25T09:30:20Z" in row
                   for row in result_rows.values()):
            raise AssertionError(f"Turn started row lost its exact ISO fixture timestamp: {result_rows!r}")
        returned = send_and_wait(process, master_fd, output, b"\x1b[D", b"j/k:move")
        returned_plain = CSI_RE.sub(b"", returned)
        for needle in (b"schedule-proof-701", b"status:running", b"queue:matched_pending/2 pending"):
            if needle not in returned_plain:
                raise AssertionError(f"Left did not restore the selected Schedule row: {returned_plain!r}")
        # The harness is 100 columns wide. Padding the id to a reserved width
        # used to push the instruction tail past the box border, so require
        # the words an operator needs to press the key a second time.
        send_and_wait(
            process,
            master_fd,
            output,
            b"x",
            b"armed: cancel schedule-proof-701 -- same key again to send",
        )
        os.write(master_fd, b"q")

    return interact



# The schedule scenario lives inside the default keyboard lane, which stops
# at an earlier scenario's exit step (#34125): an assertion added there is
# never reached. This lane runs the one scenario, so the assertion is
# measured rather than assumed.
def run_schedule_delivery_regression(executable: str) -> None:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        # Wait for a loaded row, not for the title. The title is drawn the
        # moment the screen opens, while the list still reads
        # "HTTP [loading...]" and "(not loaded yet - press r)". Waiting on the
        # title let the checks below read that frame, and they failed on a
        # list that had not arrived yet (PR check runs 36250155607,
        # 36250173553, 36251291941). The reaction fact is contiguous in raw
        # terminal output. The row's "succeeded consumed_ack" crosses an ANSI
        # style boundary; require that full row text after stripping below.
        listing = palette_go(
            process, master_fd, output, b"go schedules", b"reaction:matched_consumed_ack"
        )
        plain = CSI_RE.sub(b"", listing)
        for needle in (
            # The enqueue result and what became of the wake, side by side
            # under the WAKE and DELIVERY column names. Both words are in the
            # needle because either alone also appears in the reaction line
            # under the list, which is the surface this is not testing.
            #
            # This assertion spent a while unable to pass: it kept asking for
            # the dot glued to the second word after the row spaced it, and
            # nothing ran it. The suite selects by edited path, and a change
            # to the row's renderer does not select this file.
            b"succeeded consumed_ack",
            # The summary line's next wake, from the fixture's fsm. The
            # decoder once read fsm.next_due_at_iso while the server writes
            # fsm.next_due_at, and the fixture carried the decoder's spelling,
            # so the line was never drawn and nothing noticed.
            b"Next due:",
        ):
            if needle not in plain:
                raise AssertionError(
                    f"Schedule list omitted {needle!r}: {plain!r}"
                )
        os.write(master_fd, b"q")

    run_terminal_scenario(
        executable,
        description="Schedule list rows say what became of the wake",
        interact=interact,
        http_fixtures=schedule_detail_http_fixtures(),
    )


def run_schedule_source_status_regression(executable: str) -> None:
    binary_sha256 = hashlib.sha256(Path(executable).read_bytes()).hexdigest()
    for initial_error in (True, False):
        fixtures = schedule_detail_http_fixtures()
        good = fixtures[SCHEDULES_PATH]
        assert isinstance(good, tuple)
        recovered = json.loads(json.dumps(good[1]))
        recovered["requests"][0]["status"] = "scheduled"
        recovered["requests"][0]["payload_target"] = ("keeper:" if initial_error else "") + "encoded-keeper"
        recovered["requests"][0]["payload_keeper_name"] = "recovered-keeper"
        recovered["requests"][0]["payload"]["body"]["keeper_name"] = "recovered-keeper"
        fail_reads = threading.Event()
        recovered_reads = threading.Event()
        if initial_error:
            fail_reads.set()
        fixtures[SCHEDULES_PATH] = lambda: (
            (503, {"error": "unavailable"}) if fail_reads.is_set()
            else (200, recovered) if recovered_reads.is_set()
            else good
        )
        fixtures[SCHEDULES_PATH + "?schedule_id=schedule-proof-701"] = (
            200, {"status": "found", "schedule_id": "schedule-proof-701",
                  "wakes": [], "wake_retention_per_schedule": 1},
        )

        def interact(process, master_fd, _slave_fd, output, _base_path):
            def require(*labels: str) -> bytes:
                screen = screen_text(bytes(output))
                for label in labels:
                    if label.encode() not in screen:
                        raise AssertionError(f"Schedules omitted {label!r}: {screen!r}")
                return screen

            def evidence(phase: str) -> None:
                captured = bytes(output)
                end = captured.rfind(FRAME_END)
                if end < 0:
                    raise AssertionError("Schedules evidence has no completed terminal frame")
                end += len(FRAME_END)
                redraw = captured.rfind(FULL_REDRAW, 0, end)
                start = captured.rfind(FRAME_START, 0, redraw) if redraw >= 0 else -1
                if start < 0:
                    raise AssertionError("Schedules evidence has no complete redraw origin")
                # Preserve exact ANSI, including all complete deltas since
                # the last full redraw. Compression keeps all four measured
                # screens within Dune's output allowance for browser replay.
                print("SCHEDULE_SOURCE_PTY_EVIDENCE " + json.dumps({
                    "phase": phase, "initial_error": initial_error,
                    "has_prefix": initial_error,
                    "fixture": "isolated HTTP source status", "rows": 30, "columns": 100,
                    "binary_sha256": binary_sha256, "encoding": "zlib+base64",
                    "pty": base64.b64encode(zlib.compress(captured[start:end])).decode(),
                }), flush=True)

            # Wait on "HTTP 503", the error the Schedules pane draws, not a bare
            # "503": the palette footer prints the fixture server's random port,
            # and RC run 35815189729 drew "Port: 35039", so the bare needle matched
            # the palette frame before Schedules ever rendered.
            palette_go(process, master_fd, output, b"go schedules",
                       b"HTTP 503" if initial_error else b"status:running")
            if initial_error:
                screen = require("data unreliable:", "schedule load failed:", "HTTP 503")
                for absent in (b"Requests: 0", b"no scheduled automation", b"schedule-proof-701"):
                    if absent in screen:
                        raise AssertionError(f"Failed initial source invented data: {screen!r}")
                evidence("initial-read-failed")
            else:
                require("schedule-proof-701", "status:running", "Requests: 1")
                # The count and the next wake share one row: with nothing due
                # the second row used to be drawn blank.
                summary_rows = screen_rows(bytes(output))
                summary_row = summary_rows.get(
                    screen_row_of(summary_rows, b"Requests: 1"), b"")
                if b"Next due:" not in summary_row:
                    raise AssertionError(
                        f"the schedule count and its next wake split rows: {summary_row!r}"
                    )
                fail_reads.set()
                send_and_wait(process, master_fd, output, b"r", b"HTTP 503")
                require("이전 조회 유지 ·", "HTTP 503", "schedule-proof-701",
                        "status:running", "Requests: 1")
                evidence("retained-list-refresh-failed")
                send_and_wait(process, master_fd, output, b"\x1b[C", b"instance-proof-701")
                require("이전 조회 유지 ·", "HTTP 503", "instance-proof-701")
                # The warning belongs to the source, so it remains visible
                # while the retained detail body is scrolled.
                send_and_wait(process, master_fd, output, b"\x1b[6~", b"DELIVERY EVIDENCE")
                require("이전 조회 유지 ·", "HTTP 503")
                send_and_wait(process, master_fd, output, b"\x1b[D", b"status:running")

            recovered_reads.set()
            fail_reads.clear()
            send_and_wait(process, master_fd, output, b"r", b"status:scheduled")
            evidence("source-recovered")
            screen = require("status:scheduled", "Requests: 1", "schedule-proof-701")
            agenda_rows = [
                row for row in screen_rows(bytes(output)).values()
                if "▸".encode() in row and b"Run the detailed scheduled sweep." in row
            ]
            if len(agenda_rows) != 1 or b"recovered-keeper" not in agenda_rows[0]:
                raise AssertionError(f"agenda did not use the Keeper name field: {agenda_rows!r}")
            if b"keeper:" in agenda_rows[0] or b"encoded-keeper" in agenda_rows[0]:
                raise AssertionError(f"agenda parsed the encoded target: {agenda_rows[0]!r}")
            for absent in ("조회 실패:", "갱신 실패:", "HTTP 503", "status:running"):
                if absent.encode() in screen:
                    raise AssertionError(f"Recovered source retained old status: {screen!r}")
            os.write(master_fd, b"q")

        run_terminal_scenario(
            executable,
            description=f"Schedules source status: {'initial' if initial_error else 'refresh'}",
            interact=interact, http_fixtures=fixtures,
        )
