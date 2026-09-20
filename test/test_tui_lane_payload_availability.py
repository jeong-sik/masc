"""Actual HTTP/PTY readings retain payload fields and distinguish absent bytes."""

from __future__ import annotations

import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from typing import Any, cast
import zlib

import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs
# a suite when a pull request changes a path the suite names, so without
# this a change to the drawn text below reaches main with no scenario run.
# The two section headings it reads ("INPUT · RUN INPUT",
# "OUTPUT · RUN RESULT") are masc_tui_render.ml's.
SOURCE_MODULES = ("bin/masc_tui_render.ml", "bin/masc_tui_markdown.ml")


def run(executable: str, scenario: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[h.KEEPER_LANES_PATH] = h.keeper_lanes_response([])
    fixtures[h.STANDALONE_LANES_PATH] = h.standalone_lanes_response()
    run_id = "payload-" + scenario
    detail = cast(dict[str, Any], copy.deepcopy(h.hitl_lane_run_detail_response()[1]))
    run_record = cast(dict[str, Any], detail["run"])
    run_record["run_id"] = run_id
    run_record["lane"] = "librarian_exact"
    run_record["actor"] = "fixture"
    run_record["input"] = {"kind": "exact", "payload": {"request": "retained-input"}}
    run_record["output"] = None
    if scenario == "unavailable":
        run_record["input"] = {"kind": "exact", "payload": None}
        run_record["payload_availability"] = {
            side: {
                "state": "unavailable",
                "error": {
                    "code": "source_unavailable",
                    "message": side + "-original-missing",
                },
            }
            for side in ("input", "output")
        }
    elif scenario == "running":
        run_record["status"] = "running"
        del run_record["output"]
        del run_record["elapsed_s"]
        del run_record["selected_slot"]
        run_record["payload_availability"]["output"] = None
    elif scenario == "large-fields":
        # Synthetic renderer input, not a claim that these JEV requests ran.
        # The first field alone exceeds the preview; its siblings still matter.
        run_record["output"] = {
            "absorb_gate": {
                "status": "judged",
                "evaluations": [{"request": {"state": "x" * 70000 + "GATE_TAIL"}}],
            },
            "exact_output": {"marker": "original-model-output"},
            "before": {"marker": "before-preserved"},
            "after": {"marker": "after-preserved"},
        }
    elif scenario == "available-array":
        run_record["output"] = ["array-first", {"marker": "array-second"}]
    elif scenario == "available-empty-object":
        run_record["output"] = {}
    elif scenario == "large-scalar":
        # The quote and ASCII prefix put the old byte cut inside a Korean rune.
        run_record["output"] = "u" + "한" * 23000 + "SCALAR_TAIL"
    elif scenario == "many-fields":
        # Every value fits the former per-field bound, but together these
        # remain just below the HTTP record limit and overwhelm a frame.
        run_record["output"] = {
            f"field-{index:02}": {
                "start": f"FIELD_{index:02}_START",
                "body": "x" * 60000,
                "end": f"FIELD_{index:02}_END",
            }
            for index in range(64)
        }
    elif scenario == "many-labels":
        run_record["output"] = {
            f"field-{index:05}": f"VALUE_{index:05}" for index in range(10000)
        }
    elif scenario != "available-null":
        raise AssertionError("unknown fixture scenario")
    summary = {
        key: value
        for key, value in run_record.items()
        if key
        in (
            "run_id",
            "run_kind",
            "lane",
            "actor",
            "started_at",
            "status",
            "elapsed_s",
            "selected_slot",
        )
    }
    fixtures[h.lane_runs_path("librarian_exact")] = (
        200,
        {"runs": [summary], "has_more": False, "total": 1},
    )
    detail_reads: list[str] = []

    def read_detail():
        detail_reads.append(run_id)
        return 200, detail

    fixtures["/api/v1/dashboard/exact-lane-runs/" + run_id] = read_detail

    def interact(process, master, _slave, output, _base):
        h.palette_go(process, master, output, b"go lanes", b"Librarian")
        h.send_and_wait(
            process,
            master,
            output,
            b"/Librarian",
            re.compile(rb"\x1b\[7m[^\x1b\n]*Librarian"),
        )
        h.send_and_wait(process, master, output, b"\x1b", b"j/k:move")
        # Summary IDs are abbreviated to fit their column; the exact detail
        # request and the full detail frame below establish run identity.
        h.send_and_wait(
            process, master, output, b"\r", b"1 loaded / 1 retained \xc2\xb7 end"
        )
        h.send_and_wait(process, master, output, b"\r", b"INPUT \xc2\xb7")
        h.read_available(master, output)
        before = len(output)
        h.resize_and_wait(
            process,
            master,
            output,
            rows=42,
            columns=140,
            needle=b"OUTPUT \xc2\xb7",
            controls=(h.FULL_REDRAW,),
        )
        redraw = output.find(h.FULL_REDRAW, before)
        assert redraw >= 0
        h.wait_for_output(
            process, master, output, h.FRAME_END, start=redraw, timeout=3.0
        )
        end = output.find(h.FRAME_END, redraw) + len(h.FRAME_END)
        start = output.rfind(h.FRAME_START, before, redraw)
        assert start >= 0
        frame = bytes(output[start:end])
        screen = h.screen_text(frame)
        initial_screen = screen
        assert detail_reads == [run_id], detail_reads
        assert run_id.encode() in screen, screen
        pending = "실행 중 · 아직 출력이 기록되지 않았습니다".encode()
        unavailable = "원문 사용 불가:".encode()
        null_cell = any(
            cell.strip() == b"null"
            for line in screen.splitlines()
            for cell in line.split("│".encode())
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
        elif scenario == "running":
            assert b"RUN  running" in screen and pending in screen, screen
            assert b"retained-input" in screen, screen
            assert not null_cell and unavailable not in screen, screen
        elif scenario == "large-fields":
            assert b'"absorb_gate"' in screen and b"judged" in screen, screen
            if b"after-preserved" not in screen:
                h.send_and_wait(process, master, output, b"\x1b[F", b"after-preserved")
            h.drain_until_quiet(process, master, output)
            frame = bytes(output[start:])
            screen = h.screen_text(bytes(output))
            for needle in (
                b'"exact_output"',
                b"original-model-output",
                b'"before"',
                b"before-preserved",
                b'"after"',
                b"after-preserved",
                b"truncated, total",
            ):
                assert needle in screen, (needle, screen)
            assert b"GATE_TAIL" not in frame, frame
        elif scenario == "available-array":
            assert b"array-first" in screen and b"array-second" in screen, screen
        elif scenario == "available-empty-object":
            assert any(
                cell.strip() == b"{}"
                for line in screen.splitlines()
                for cell in line.split("│".encode())
            ), screen
        elif scenario == "large-scalar":
            h.send_and_wait(process, master, output, b"\x1b[F", b"truncated, total")
            h.drain_until_quiet(process, master, output)
            frame = bytes(output[start:])
            screen = h.screen_text(bytes(output))
            frame.decode("utf-8", errors="strict")
            assert "\ufffd".encode() not in frame, frame
            assert "한".encode() in screen, screen
            assert b"SCALAR_TAIL" not in frame, frame
        elif scenario == "many-fields":
            assert b'"field-00"' in screen and b"FIELD_00_START" in screen, screen
            assert b"truncated, total" in screen, screen
            h.send_and_wait(process, master, output, b"\x1b[F", b"FIELD_63_START")
            h.drain_until_quiet(process, master, output)
            screen = h.screen_text(bytes(output))
            assert b'"field-63"' in screen, screen
        elif scenario == "many-labels":
            h.send_and_wait(
                process, master, output, b"\x1b[F", b"field(s) not rendered"
            )
            h.drain_until_quiet(process, master, output)
            screen = h.screen_text(bytes(output))
            assert b'"field-09999"' in screen and b"VALUE_09999" in screen, screen
            assert re.search(rb"[1-9][0-9]* more field\(s\) not rendered", screen), (
                screen
            )
        assert b"INPUT \xc2\xb7 RUN INPUT" in initial_screen, initial_screen
        assert b"OUTPUT \xc2\xb7 RUN RESULT" in initial_screen, initial_screen
        assert b"MODEL RESPONSE" not in initial_screen, initial_screen
        print(
            "LANE_PAYLOAD_PTY_EVIDENCE "
            + json.dumps(
                {
                    "scenario": scenario,
                    "run_id": run_id,
                    "detail_reads": detail_reads,
                    "rows": 42,
                    "columns": 140,
                    "binary_sha256": hashlib.sha256(
                        Path(executable).read_bytes()
                    ).hexdigest(),
                    "encoding": "zlib+base64",
                    "pty": base64.b64encode(zlib.compress(frame)).decode(),
                }
            ),
            flush=True,
        )
        os.write(master, b"q")

    h.run_terminal_scenario(
        executable,
        description="Lane payload availability: " + scenario,
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    for scenario in (
        "unavailable",
        "available-null",
        "running",
        "large-fields",
        "available-array",
        "available-empty-object",
        "large-scalar",
        "many-fields",
        "many-labels",
    ):
        run(os.path.abspath(sys.argv[1]), scenario)
    print("TUI lane original payload availability: PASS")
