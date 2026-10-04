"""Keeper Automation draws mixed rows and suppresses a held occurrence's clocks."""

import copy
import os
import subprocess
import sys
from itertools import pairwise
from pathlib import Path
from typing import Any, cast

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_schedule as _keyboard_schedule



SCHEDULES = _keyboard_schedule.SCHEDULES_PATH


def mixed_rows_fixtures() -> _keyboard_harness.HttpFixtures:
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    source = _keyboard_schedule.schedule_detail_http_fixtures()[SCHEDULES]
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
    rows = _keyboard_harness.screen_rows(bytes(output))
    labels = ("STATUS", "TRIGGERED", "OUTCOME", "RECEIVED", "RECURRENCE")
    header = next(
        (
            line.decode()
            for line in rows.values()
            if all(label.encode() in line for label in labels)
        ),
        None,
    )
    if header is None:
        raise AssertionError(f"Automation lost its column headers: {rows!r}")
    bounds = {
        label: (header.index(label), header.index(following))
        for label, following in pairwise(labels)
    }

    def cells(line: bytes) -> dict[str, str]:
        # These fixture columns contain ASCII and single-cell marks. Decode
        # UTF-8 before slicing so a mark does not shift byte offsets.
        text = line.decode()
        return {
            label: text[start:end].strip() for label, (start, end) in bounds.items()
        }

    positions = {}
    for name in ("success-proof", "failure-proof", "closed-proof", "held-proof"):
        positions[name] = _keyboard_harness.screen_row_of(rows, name.encode())
        if positions[name] < 0:
            raise AssertionError(f"Automation lost {name}: {rows!r}")
    for name, status, outcome, triggered, received in (
        ("success-proof", b"succeeded", b"consumed_ack", b"11:10", b"11:12"),
        ("failure-proof", b"running", b"failed", b"12:10", b"12:12"),
        ("closed-proof", b"cancelled", b"consumed_ack", b"13:10", b"13:12"),
    ):
        line = rows[positions[name]]
        actual = cells(line)
        expected = {
            "STATUS": status.decode(),
            "OUTCOME": outcome.decode(),
            "TRIGGERED": f"2026-08-25 {triggered.decode()}:00",
            "RECEIVED": f"2026-08-25 {received.decode()}:00",
        }
        if actual != expected:
            raise AssertionError(f"{name} column mismatch: {actual!r} != {expected!r}")
    held = cells(rows[positions["held-proof"]])
    if held != {"STATUS": "due", "TRIGGERED": "—", "OUTCOME": "—", "RECEIVED": "—"}:
        raise AssertionError(f"Held row reused previous occurrence cells: {held!r}")
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


def reject_swapped_columns(output: bytearray) -> None:
    controls = []
    clocks = bytes(output)
    for triggered, received in (
        (b"11:10", b"11:12"),
        (b"12:10", b"12:12"),
        (b"13:10", b"13:12"),
    ):
        clocks = (
            clocks.replace(triggered, b"CLOCK_SWAP")
            .replace(received, triggered)
            .replace(b"CLOCK_SWAP", received)
        )
    controls.append(("TRIGGERED/RECEIVED", clocks))
    # Fixed-width replacements keep column boundaries unchanged.
    status = (
        bytes(output)
        .replace(b"running  ", b"STATE_SWAP")
        .replace(b"failed   ", b"running  ")
        .replace(b"STATE_SWAP", b"failed   ")
    )
    controls.append(("STATUS/OUTCOME", status))
    for label, swapped in controls:
        try:
            checked_frame(bytearray(swapped))
        except AssertionError as error:
            if "column mismatch" not in str(error):
                raise AssertionError(
                    f"{label} control failed outside cell semantics"
                ) from error
        else:
            raise AssertionError(f"Automation accepted swapped {label} columns")


def run(executable: str, frame_path: str | None = None) -> None:
    def interact(
        process: subprocess.Popen[bytes],
        fd: int,
        _slave: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        _keyboard_harness.resize_and_wait(
            process, fd, output, rows=40, columns=420, needle=b"MASC Dashboard"
        )
        _keyboard_harness.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        _keyboard_harness.select_keeper_row(process, fd, output, b"alpha")
        _keyboard_harness.send_and_wait(process, fd, output, b"\r", "▸Info".encode())
        _keyboard_harness.send_and_wait(process, fd, output, b"[", "▸Runs".encode())
        before = len(output)
        _keyboard_harness.send_and_wait(process, fd, output, b"[", "▸Automation".encode())
        _keyboard_harness.wait_for_output(process, fd, output, b"held-proof", start=before, timeout=5)
        _keyboard_harness.wait_for_output(
            process,
            fd,
            output,
            _keyboard_harness.FRAME_END,
            start=_keyboard_harness.end_of_needle(output, b"held-proof", before),
            timeout=5,
        )
        if frame_path is not None:
            Path(frame_path).write_bytes(_keyboard_harness.screen_text(bytes(output)))
            Path(frame_path + ".ansi").write_bytes(bytes(output))
        checked_frame(output)
        reject_swapped_columns(output)
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Keeper Automation draws mixed rows and held occurrence blanks",
        interact=interact,
        http_fixtures=mixed_rows_fixtures(),
        extra_env={"TZ": "UTC"},
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]), sys.argv[2] if len(sys.argv) > 2 else None)
    print("Keeper Automation mixed rows: PASS")
