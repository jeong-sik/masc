"""Actual HTTP/PTY proof that durable run history extends beyond its first page."""
from __future__ import annotations

import base64
import copy
import hashlib
import json
import os
import re
import sys
from pathlib import Path

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_keepers as _keyboard_keepers




def run(executable: str) -> None:
    lane = "verifier_exact"
    first_path = _keyboard_keepers.lane_runs_path(lane)
    next_path = first_path + "&before_started_at=100.125&before_run_id=run-002"
    detail_path = "/api/v1/dashboard/exact-lane-runs/run-001"
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    fixtures[_keyboard_keepers.KEEPER_LANES_PATH] = _keyboard_keepers.keeper_lanes_response([])
    fixtures[_keyboard_keepers.LANE_INVENTORY_PATH] = _keyboard_keepers.lane_inventory_response()
    template = _keyboard_keepers.verifier_lane_runs_response()[1]["runs"][0]

    # The list draws no run id, so each row is told apart on screen by the
    # task it verified; the pages still turn on the run id.
    def row(index: int) -> dict:
        return {**template, "run_id": f"run-{index:03d}",
                "subject_id": f"task-{index:03d}", "started_at": 100.125}

    first = (200, {"runs": [row(i) for i in range(51, 1, -1)],
                   "has_more": True, "total": 51})
    older = (200, {"runs": [row(1)], "has_more": False, "total": 51})
    fixtures[first_path] = first
    page_calls = []

    def fail_next():
        page_calls.append("failed")
        return 503, {"error": "older history temporarily unavailable"}

    def next_page():
        page_calls.append("succeeded")
        return older

    fixtures[next_path] = fail_next
    _, detail = _keyboard_keepers.verifier_lane_run_detail_response()
    detail = copy.deepcopy(detail)
    detail["run"]["run_id"] = "run-001"
    detail["run"]["started_at"] = 100.125
    detail_calls = []

    def read_detail():
        detail_calls.append("run-001")
        return 200, detail

    fixtures[detail_path] = read_detail

    def interact(process, master, _slave, output, _base_path):
        _keyboard_harness.resize_and_wait(process, master, output, rows=30, columns=150,
                          needle=b"MASC Dashboard")
        _keyboard_harness.palette_go(process, master, output, b"go lanes", b"Verifier")
        _keyboard_harness.send_and_wait(process, master, output, b"/Verifier",
                        re.compile(rb"\x1b\[7m[^\x1b\n]*Verifier"))
        _keyboard_harness.send_and_wait(process, master, output, b"\x1b", b"j/k:move")
        _keyboard_harness.send_and_wait(process, master, output, b"\r", b"50 loaded / 51 retained")
        _keyboard_harness.send_and_wait(process, master, output, b"]", b"older history temporarily unavailable")
        screen = _keyboard_harness.screen_text(bytes(output))
        if b"50 loaded / 51 retained" not in screen or b"task-051" not in screen:
            raise AssertionError(f"failed page hid retained rows: {screen!r}")
        fixtures[next_path] = next_page
        _keyboard_harness.send_and_wait(process, master, output, b"]", b"51 loaded / 51 retained")
        _keyboard_harness.read_available(master, output)
        before_resize = len(output)
        _keyboard_harness.resize_and_wait(process, master, output, rows=30, columns=149,
                          needle=b"51 loaded / 51 retained", controls=(_keyboard_harness.FULL_REDRAW,))
        redraw = output.find(_keyboard_harness.FULL_REDRAW, before_resize)
        if redraw < 0:
            raise AssertionError("pagination resize did not redraw the terminal")
        _keyboard_harness.wait_for_output(process, master, output, _keyboard_harness.FRAME_END, start=redraw, timeout=3.0)
        screen = _keyboard_harness.screen_text(bytes(output))
        if b"task-001" not in screen or b"older history temporarily unavailable" in screen:
            raise AssertionError(f"older row or recovered page status is wrong: {screen!r}")
        captured = bytes(output)
        end = captured.rfind(_keyboard_harness.FRAME_END) + len(_keyboard_harness.FRAME_END)
        redraw = captured.rfind(_keyboard_harness.FULL_REDRAW, 0, end)
        start = captured.rfind(_keyboard_harness.FRAME_START, 0, redraw)
        if min(start, redraw) < 0:
            raise AssertionError("pagination evidence has no complete redraw")
        frame = captured[start:end]
        _keyboard_harness.send_and_wait(process, master, output, b"\r", b"VERIFICATION REQUEST")
        if detail_calls != ["run-001"]:
            raise AssertionError(f"Enter did not open the exact older run: {detail_calls!r}")
        _keyboard_harness.send_and_wait(process, master, output, b"\x1b", b"51 loaded / 51 retained")
        # A current refresh replaces the accumulated history instead of
        # attaching a fresh head to an older cursor's rows.
        fixtures[first_path] = (200, {"runs": [row(99)], "has_more": False, "total": 1})
        _keyboard_harness.send_and_wait(process, master, output, b"r", b"1 loaded / 1 retained")
        _keyboard_harness.resize_and_wait(process, master, output, rows=30, columns=150,
                          needle=b"task-099", controls=(_keyboard_harness.FULL_REDRAW,))
        screen = _keyboard_harness.screen_text(bytes(output))
        if b"task-001" in screen:
            raise AssertionError(f"refresh retained the old cursor page: {screen!r}")
        if page_calls != ["failed", "succeeded"]:
            raise AssertionError(f"unexpected page requests: {page_calls!r}")
        print("LANE_PAGINATION_PTY_EVIDENCE " + json.dumps({
            "fixture": "51 retained runs; tied timestamp exact run-ID cursor; failed page retry; detail; refresh",
            "next_path": next_path, "page_results": page_calls, "detail_reads": detail_calls,
            "rows": 30, "columns": 149,
            "binary_sha256": hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
            "encoding": "base64", "pty": base64.b64encode(frame).decode(),
        }), flush=True)
        os.write(master, b"q")

    _keyboard_harness.run_terminal_scenario(executable, description="Standalone history cursor pages preserve exact source",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("TUI lane history pagination: PASS")
