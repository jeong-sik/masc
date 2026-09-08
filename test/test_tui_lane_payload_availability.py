"""Actual HTTP/PTY readings distinguish missing originals from JSON null."""
from __future__ import annotations

import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import zlib

import test_tui_keyboard_input as h


def run(executable: str, scenario: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[h.KEEPER_LANES_PATH] = h.keeper_lanes_response([])
    fixtures[h.STANDALONE_LANES_PATH] = h.standalone_lanes_response()
    run_id = "payload-" + scenario
    detail = copy.deepcopy(h.hitl_lane_run_detail_response()[1])
    run_record = detail["run"]
    run_record["run_id"] = run_id
    run_record["lane"] = "board_attention_exact"
    run_record["actor"] = "fixture"
    run_record["input"] = {"kind": "exact", "payload": {"request": "retained-input"}}
    run_record["output"] = None
    if scenario == "unavailable":
        run_record["input"] = {"kind": "exact", "payload": None}
        run_record["payload_availability"] = {
            side: {"state": "unavailable", "error": {
                "code": "source_unavailable", "message": side + "-original-missing",
            }} for side in ("input", "output")
        }
    elif scenario == "running":
        run_record["status"] = "running"
        del run_record["output"]
        del run_record["elapsed_s"]
        del run_record["selected_slot"]
        run_record["payload_availability"]["output"] = None
    elif scenario != "available-null":
        raise AssertionError("unknown fixture scenario")
    summary = {
        key: value for key, value in run_record.items()
        if key in ("run_id", "run_kind", "lane", "actor", "started_at",
                   "status", "elapsed_s", "selected_slot")
    }
    fixtures[h.lane_runs_path("board_attention_exact")] = (
        200, {"runs": [summary], "has_more": False, "total": 1},
    )
    detail_reads: list[str] = []

    def read_detail():
        detail_reads.append(run_id)
        return 200, detail

    fixtures["/api/v1/dashboard/exact-lane-runs/" + run_id] = read_detail

    def interact(process, master, _slave, output, _base):
        h.palette_go(process, master, output, b"go lanes", b"Board Attention")
        # Summary IDs are abbreviated to fit their column; the exact detail
        # request and the full detail frame below establish run identity.
        h.send_and_wait(process, master, output, b"\r", b"1 loaded / 1 retained \xc2\xb7 end")
        h.send_and_wait(process, master, output, b"\r", b"INPUT \xc2\xb7 PROMPT PAYLOAD")
        h.read_available(master, output)
        before = len(output)
        h.resize_and_wait(process, master, output, rows=30, columns=140,
                          needle=b"OUTPUT \xc2\xb7 MODEL RESPONSE", controls=(h.FULL_REDRAW,))
        redraw = output.find(h.FULL_REDRAW, before)
        assert redraw >= 0
        h.wait_for_output(process, master, output, h.FRAME_END, start=redraw, timeout=3.0)
        end = output.find(h.FRAME_END, redraw) + len(h.FRAME_END)
        start = output.rfind(h.FRAME_START, before, redraw)
        assert start >= 0
        frame = bytes(output[start:end])
        screen = h.screen_text(frame)
        assert detail_reads == [run_id], detail_reads
        assert run_id.encode() in screen, screen
        pending = "실행 중 · 아직 출력이 기록되지 않았습니다".encode()
        unavailable = "원문 사용 불가:".encode()
        null_cell = any(
            cell.strip() == b"null"
            for line in screen.splitlines() for cell in line.split("│".encode())
        )
        if scenario == "unavailable":
            assert b"RUN  succeeded" in screen, screen
            assert screen.count(unavailable) == 2, screen
            assert b"input-original-missing" in screen, screen
            assert b"output-original-missing" in screen, screen
            assert pending not in screen and not null_cell, screen
            assert b"run has not completed" not in screen, screen
        elif scenario == "available-null":
            assert b"RUN  succeeded" in screen and null_cell, screen
            assert b"retained-input" in screen, screen
            assert pending not in screen and unavailable not in screen, screen
            assert b"run has not completed" not in screen, screen
        else:
            assert b"RUN  running" in screen and pending in screen, screen
            assert b"retained-input" in screen, screen
            assert not null_cell and unavailable not in screen, screen
        print("LANE_PAYLOAD_PTY_EVIDENCE " + json.dumps({
            "scenario": scenario, "run_id": run_id, "detail_reads": detail_reads,
            "rows": 30, "columns": 140,
            "binary_sha256": hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
            "encoding": "zlib+base64", "pty": base64.b64encode(zlib.compress(frame)).decode(),
        }), flush=True)
        os.write(master, b"q")

    h.run_terminal_scenario(executable, description="Lane payload availability: " + scenario,
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    for scenario in ("unavailable", "available-null", "running"):
        run(os.path.abspath(sys.argv[1]), scenario)
    print("TUI lane original payload availability: PASS")
