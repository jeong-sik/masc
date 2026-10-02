"""Keeper Automation draws mixed rows and suppresses a held occurrence's clocks."""

import copy
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, cast

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
    "bin/masc_tui_render_schedule.ml",
    "bin/masc_tui_loader.ml",
)

SCHEDULES = h.SCHEDULES_PATH


def mixed_rows_fixtures() -> h.HttpFixtures:
    fixtures = h.keeper_runtime_http_fixtures()
    source = h.schedule_detail_http_fixtures()[SCHEDULES]
    assert isinstance(source, tuple)
    payload = copy.deepcopy(cast(dict[str, Any], source[1]))
    prototype = payload["requests"][0]
    rows = []
    for name, status, wake_status, triggered, received in (
        ("success-proof", "succeeded", "succeeded", "11:10", "11:12"),
        ("failure-proof", "running", "failed", "12:10", "12:12"),
        ("closed-proof", "cancelled", "succeeded", "13:10", "13:12"),
        ("held-proof", "due", "succeeded", "14:10", "14:12"),
    ):
        row = copy.deepcopy(prototype)
        row["schedule_id"] = name
        row["schedule_instance_id"] = name + "-instance"
        row["status"] = status
        row["payload_summary"] = name
        row["last_wake"] = {
            "status": wake_status,
            "started_at_iso": f"2026-08-25T{triggered}:00Z",
            "error": "synthetic wake failure" if wake_status == "failed" else None,
        }
        row["keeper_reaction_evidence"]["stimulus_recorded_at_iso"] = (
            f"2026-08-25T{received}:00Z"
        )
        # Deliberately distinct: RECEIVED must not read the acknowledgement.
        row["keeper_reaction_evidence"]["event_queue_ack_recorded_at_iso"] = (
            "2026-08-25T19:59:00Z"
        )
        if name == "held-proof":
            row["runner_hold"] = {
                "occurrence_id": "held-proof-occurrence",
                "due_at": 1787667000.0,
                "due_at_iso": "2026-08-25T14:10:00Z",
                "observed_at": 1787667300.0,
                "observed_at_iso": "2026-08-25T14:15:00Z",
                "reason": {"kind": "previous_occurrence_unconsumed"},
            }
        rows.append(row)
    # Closed rows lead the response: the renderer must partition the page.
    payload["requests"] = rows
    payload["request_count"] = len(rows)
    for target in ("keeper%3Aalpha", "keeper%3aalpha", "keeper:alpha"):
        fixtures[f"{SCHEDULES}?payload_target={target}"] = (200, payload)
    return fixtures


def checked_frame(output: bytearray) -> dict[int, bytes]:
    rows = h.screen_rows(bytes(output))
    for header in (b"STATUS", b"TRIGGERED", b"RECEIVED", b"OUTCOME"):
        if not any(header in line for line in rows.values()):
            raise AssertionError(f"Automation lost {header!r}: {rows!r}")
    positions = {}
    for name in ("success-proof", "failure-proof", "closed-proof", "held-proof"):
        positions[name] = h.screen_row_of(rows, name.encode())
        if positions[name] < 0:
            raise AssertionError(f"Automation lost {name}: {rows!r}")
    for name, status, outcome, triggered, received in (
        ("success-proof", b"succeeded", b"consumed_ack", b"11:10", b"11:12"),
        ("failure-proof", b"running", b"failed", b"12:10", b"12:12"),
        ("closed-proof", b"cancelled", b"consumed_ack", b"13:10", b"13:12"),
    ):
        line = rows[positions[name]]
        for value in (status, outcome, triggered, received):
            if value not in line:
                raise AssertionError(f"{name} lost {value!r}: {line!r}")
        if b"19:59" in line:
            raise AssertionError(f"RECEIVED used ack time: {line!r}")
    held = rows[positions["held-proof"]]
    if b"due" not in held or held.count("—".encode()) < 3:
        raise AssertionError(f"Held row lost suppressed occurrence cells: {held!r}")
    if any(value in held for value in (b"14:10", b"14:12", b"succeeded", b"19:59")):
        raise AssertionError(f"Held row reused previous occurrence: {held!r}")
    closed_rule = next(
        (
            index
            for index, line in rows.items()
            if line.lstrip().startswith("── closed ·".encode())
        ),
        -1,
    )
    if not (
        max(positions["failure-proof"], positions["held-proof"])
        < closed_rule
        < min(positions["success-proof"], positions["closed-proof"])
    ):
        raise AssertionError(f"Live/closed partition is missing: {rows!r}")
    return rows


def run(executable: str, frame_path: str | None = None) -> None:
    def interact(
        process: subprocess.Popen[bytes],
        fd: int,
        _slave: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        h.resize_and_wait(
            process, fd, output, rows=40, columns=420, needle=b"MASC Dashboard"
        )
        h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"\r", "▸Info".encode())
        h.send_and_wait(process, fd, output, b"[", "▸Runs".encode())
        before = len(output)
        h.send_and_wait(process, fd, output, b"[", "▸Automation".encode())
        h.wait_for_output(process, fd, output, b"held-proof", start=before, timeout=5)
        h.wait_for_output(
            process,
            fd,
            output,
            h.FRAME_END,
            start=h.end_of_needle(output, b"held-proof", before),
            timeout=5,
        )
        if frame_path is not None:
            Path(frame_path).write_bytes(h.screen_text(bytes(output)))
            Path(frame_path + ".ansi").write_bytes(bytes(output))
        checked_frame(output)
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Keeper Automation draws mixed rows and held occurrence blanks",
        interact=interact,
        http_fixtures=mixed_rows_fixtures(),
        extra_env={"TZ": "UTC"},
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]), sys.argv[2] if len(sys.argv) > 2 else None)
    print("Keeper Automation mixed rows: PASS")
