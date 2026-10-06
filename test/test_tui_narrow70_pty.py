"""Narrow (<74 col) PTY receipt for the table floors.

Launches the built TUI at 70 columns through the shared keyboard harness
(the same fixtures, launch and exit discipline as the PTY suites), walks
three table surfaces, and asserts every drawn row fits the pane. The
evidence line printed at the end is the receipt the narrow-mode RFC's
verification section cites: 70 columns is inside the sub-74 span the
floors were published for, so a pane that leaked a wider row than the
terminal gives it would fail here.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import sys
import unicodedata

import tui_keyboard_harness as _keyboard_harness
from tui_keyboard_harness import (
    keeper_runtime_http_fixtures,
    read_available,
    row_budget_http_fixtures,
    run_terminal_scenario,
    screen_rows,
    send_and_wait,
    tab_until,
)


def cells(text: str) -> int:
    total = 0
    for char in text:
        total += 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
    return total


def audit(output: bytearray, surface: str, evidence: dict, columns: int = 70) -> None:
    rows = screen_rows(bytes(output))
    drawn = {row: text for row, text in rows.items() if text.strip()}
    widest = 0
    for row, raw in drawn.items():
        text = raw.decode("utf-8", "replace")
        widest = max(widest, cells(text))
        if cells(text) > columns:
            raise AssertionError(
                f"{surface}: row {row} draws {cells(text)} cells in a {columns}-column"
                f" pane: {text!r}"
            )
    evidence[surface] = {
        "rows_drawn": len(drawn),
        "widest_row_cells": widest,
        "screen": base64.b64encode(
            "\n".join(drawn[r].decode("utf-8", "replace") for r in sorted(drawn)).encode()
        ).decode(),
    }
    print(f"narrow70: {surface} drew {len(drawn)} rows, widest {widest}/{columns} cells")


def interact(process, master_fd, _slave_fd, output, _base_path) -> None:
    evidence: dict[str, object] = {}
    audit(output, "dashboard", evidence)
    send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
    audit(output, "keepers", evidence)
    send_and_wait(process, master_fd, output, b"\t", b"Board")
    audit(output, "board", evidence)
    read_available(master_fd, output)
    print("NARROW70_PTY_EVIDENCE " + json.dumps(evidence, sort_keys=True), flush=True)
    os.write(master_fd, b"q")


def main() -> None:
    executable = _keyboard_harness.tui_executable(sys.argv[1])
    fixtures = {**keeper_runtime_http_fixtures(), **row_budget_http_fixtures()}
    run_terminal_scenario(
        executable,
        description="narrow 70-column surfaces stay inside the pane",
        interact=interact,
        terminal_cols=70,
        terminal_rows=30,
        http_fixtures=fixtures,
        workspace="a",
    )
    digest = hashlib.sha256(open(executable, "rb").read()).hexdigest()
    print(f"narrow70 receipt: PASS exe_sha256={digest} columns=70 rows=30", flush=True)


if __name__ == "__main__":
    main()
