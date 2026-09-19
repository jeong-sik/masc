"""Confirm a Goal through real key input and controlled HTTP responses."""

from __future__ import annotations

import base64
import copy
import json
import os
import subprocess
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_http.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_planning_detail.ml",
)


def run(executable: str, *, replace_proof: bool) -> None:
    goal_id = "goal-confirmation"
    goal = h.planning_goal(goal_id, "plan-alpha-29424")
    goal.update(phase="awaiting_confirmation", criterion_revision="revision-1")
    verdict = {
        "outcome": "proven",
        "reason": None,
        "request_id": "request-1",
        "verification_run_id": "run-1",
        "criterion": {
            "revision": "revision-1",
            "title": goal["title"],
            "metric": goal["metric"],
            "target_value": goal["target_value"],
        },
        "authority": {"kind": "system_llm_agent", "actor": "run-1"},
        "evidence": "All measured scenarios passed",
        "recorded_at": "2026-09-19T08:00:00Z",
    }
    proof = {"state": "proof_proven", "verdict": verdict}
    goal["verification"] = {"completion": proof}
    response = {
        "goal": goal,
        "verification": {"goal_id": goal_id, "completion": proof},
    }
    fixtures = h.overview_event_http_fixtures()
    fixtures[h.PLANNING_PATH] = h.planning_snapshot([goal])
    read_count = 0
    posted: list[object] = []

    def read() -> h.HttpResponse:
        nonlocal read_count
        read_count += 1
        return 200, response

    def submit(body: bytes) -> h.HttpResponse:
        posted.append(json.loads(body))
        expected = {
            "goal_id": goal_id,
            "criterion_revision": "revision-1",
            "request_id": "request-1",
            "verification_run_id": "run-1",
        }
        if posted[-1] != expected:
            return 400, {"error": "the TUI did not retain the displayed binding"}
        if replace_proof:
            return 400, {"error": "confirmation proof changed"}
        confirmed = copy.deepcopy(response)
        confirmed_goal = dict(goal, phase="completed")
        confirmed["goal"] = confirmed_goal
        confirmed["verification"] = {
            "goal_id": goal_id,
            "completion": dict(
                proof,
                state="human_confirmed",
                operator_id="operator",
                confirmed_at="2026-09-19T08:01:00Z",
            ),
        }
        fixtures[h.PLANNING_PATH] = h.planning_snapshot([confirmed_goal])
        return 200, confirmed

    fixtures[f"/api/v1/goals/confirmation?goal_id={goal_id}"] = read
    fixtures["/api/v1/goals/confirmation"] = h.RequestHttpResponse(submit)

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        h.resize_and_wait(
            process,
            master_fd,
            output,
            rows=50,
            columns=160,
            needle=b"MASC Overview",
            final_cursor=b"\x1b[?25l",
        )
        h.open_loaded_planning(process, master_fd, output)
        # Keep the Goal visible when its phase changes to completed.
        for phase_filter in (b"completed", b"dropped", b"all"):
            h.send_and_wait(process, master_fd, output, b"f", b"filter:" + phase_filter)
        h.send_and_wait(process, master_fd, output, b"\r", b"[a] Confirm proof")
        proof_frame = h.send_and_wait(
            process, master_fd, output, b"a", b"CONFIRM THIS PROOF"
        )
        h.wait_for_output(
            process, master_fd, output, b"Verifier run: run-1", start=0, timeout=5.0
        )
        if read_count != 1 or posted:
            raise AssertionError("first key must read the proof without posting")
        if replace_proof:
            verdict["verification_run_id"] = "run-2"
        needle = (
            b"confirmation proof changed" if replace_proof else b"reached its target"
        )
        result_frame = h.send_and_wait(process, master_fd, output, b"a", needle)
        if read_count != 1 or len(posted) != 1:
            raise AssertionError(
                "second key must post once without reading a new proof"
            )
        if posted[0] != {
            "goal_id": goal_id,
            "criterion_revision": "revision-1",
            "request_id": "request-1",
            "verification_run_id": "run-1",
        }:
            raise AssertionError(
                f"confirmation changed the displayed binding: {posted!r}"
            )
        print(
            "GOAL_CONFIRMATION_PTY_EVIDENCE "
            + json.dumps(
                {
                    "server": "controlled_http_fixture",
                    "proof_changed": replace_proof,
                    "get_requests": read_count,
                    "post_requests": posted,
                    "encoding": "base64",
                    "proof_frame": base64.b64encode(proof_frame).decode(),
                    "result_frame": base64.b64encode(result_frame).decode(),
                }
            )
        )
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Goal confirmation preserves the inspected proof"
        + (" when the server proof changes" if replace_proof else ""),
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    for replaced in (False, True):
        run(os.path.abspath(sys.argv[1]), replace_proof=replaced)
    print("Goal confirmation key and HTTP wiring: PASS")
