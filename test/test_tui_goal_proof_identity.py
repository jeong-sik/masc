"""Real HTTP/PTY proof states remain distinct from the Goal's current phase."""
from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path
import sys
import zlib

import test_tui_keyboard_input as h


def run(executable: str, scenario: str) -> None:
    fixtures = h.overview_event_http_fixtures()
    goal_id = "proof-" + scenario
    goal = h.planning_goal(goal_id, "plan-alpha-29424")
    goal["metric"] = "completed-runs"
    goal["target_value"] = "4"
    stamp = "2026-09-09T01:00:00Z"
    criterion = {
        "revision": "criterion-old" if scenario == "stale" else "criterion-current",
        "title": goal["title"], "metric": goal["metric"],
        "target_value": "3" if scenario == "stale" else "4",
    }
    verdict = {
        "outcome": "refuted" if scenario == "refuted" else "proven",
        "reason": "measurement-refutes-four" if scenario == "refuted" else None,
        "request_id": "request-" + scenario, "criterion": criterion,
        "verification_run_id": "run-" + scenario,
        "authority": {"kind": "system_llm_agent", "actor": "verifier_exact"},
        "evidence": "retained-measurement-" + scenario, "recorded_at": stamp,
    }
    completion = {
        "state": "proof_refuted" if scenario == "refuted" else "proof_proven",
        "verdict": verdict,
    }
    if scenario == "stale":
        completion = {"state": "stale_criterion", "historical_completion": completion}
    goal["verification"] = {"goal_id": goal_id, "completion": completion, "updated_at": stamp}
    if scenario == "unreadable":
        goal["verification"] = {"state": "ledger_error", "detail": "primary-ledger-unavailable"}
    elif scenario == "proven":
        goal["phase"] = "completed"
    elif scenario not in ("stale", "refuted"):
        raise AssertionError("unknown scenario")
    planning = h.planning_snapshot([goal])
    planning[1]["rollup"]["active_count"] = int(scenario != "proven")
    planning[1]["rollup"]["done_count"] = int(scenario == "proven")
    reads: list[str] = []

    def read_planning():
        reads.append(h.PLANNING_PATH)
        return planning

    detail_path = "/api/v1/dashboard/goals/detail?goal_id=" + goal_id

    def read_detail():
        reads.append(detail_path)
        return 200, {"approval_queue_state": {"state": "ready"}, "timeline": []}

    fixtures[h.PLANNING_PATH] = read_planning
    fixtures[detail_path] = read_detail
    notice = b"criterion changed; previous proof is historical"
    evidence = verdict["evidence"].encode()
    expected = b"primary-ledger-unavailable" if scenario == "unreadable" else evidence

    def interact(process, master, _slave, output, _base):
        h.open_loaded_planning(process, master, output)
        h.send_and_wait(process, master, output, b"\x1b[C", expected)
        h.read_available(master, output)
        before = len(output)
        h.resize_and_wait(process, master, output, rows=40, columns=140,
                          needle=expected, controls=(h.FULL_REDRAW,))
        redraw = output.find(h.FULL_REDRAW, before)
        assert redraw >= 0
        h.wait_for_output(process, master, output, h.FRAME_END, start=redraw, timeout=3.0)
        end = output.find(h.FRAME_END, redraw) + len(h.FRAME_END)
        start = output.rfind(h.FRAME_START, before, redraw)
        assert start >= 0
        frame = bytes(output[start:end])
        screen = h.screen_text(frame)
        assert h.PLANNING_PATH in reads and detail_path in reads, reads
        assert goal_id.encode() in screen and b"completed-runs = 4" in screen, screen
        assert expected in screen, screen
        if scenario == "stale":
            assert notice in screen, screen
            # Historical proof is drawn with the existing Note (dim) tone,
            # not the success colour of a current Proven verdict.
            assert b"\x1b[2m" + notice in frame, frame
            assert b"\x1b[2m" + evidence in frame, frame
        else:
            assert notice not in screen, screen
        if scenario == "unreadable":
            assert b"verification ledger unreadable" in screen, screen
            assert evidence not in screen, screen
        print("GOAL_PROOF_PTY_EVIDENCE " + json.dumps({
            "scenario": scenario, "goal_id": goal_id, "phase": goal["phase"],
            "http_reads": reads, "planning_response": planning[1],
            "rows": 40, "columns": 140,
            "binary_sha256": hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
            "encoding": "zlib+base64", "pty": base64.b64encode(zlib.compress(frame)).decode(),
        }), flush=True)
        os.write(master, b"q")

    h.run_terminal_scenario(executable, description="Goal proof identity: " + scenario,
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    for scenario in ("proven", "stale", "refuted", "unreadable"):
        run(os.path.abspath(sys.argv[1]), scenario)
    print("TUI Goal current and historical proof: PASS")
