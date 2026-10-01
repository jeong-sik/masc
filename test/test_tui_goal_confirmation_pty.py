"""Confirm a Goal through real key input and controlled HTTP responses."""

from __future__ import annotations

import base64
import copy
import json
import os
import re
import subprocess
import sys
import threading

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_planning as _keyboard_planning

SOURCE_MODULES = (
    "bin/masc_tui_home.ml",
    "bin/masc_tui_home.mli",
    "bin/masc_tui.ml",
    "bin/masc_tui_http.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_planning_detail.ml",
    "bin/masc_tui_planning_detail.mli",
    "bin/masc_tui_render_prim.ml",
    "bin/masc_tui_types.ml",
    "test/tui_keyboard_approvals.py",
    "test/tui_keyboard_harness.py",
    "test/tui_keyboard_planning.py",
    "bin/masc_tui_async_protocol.ml",
    "bin/masc_tui_async_protocol.mli",
)


def run(executable: str, *, replace_proof: bool, long_binding: bool = False) -> None:
    goal_id = "goal-confirmation"
    goal = _keyboard_harness.planning_goal(goal_id, "plan-alpha-29424")
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
    if long_binding:
        goal["title"] = "plan-alpha-29424 " + "criterion title " * 100 + "TITLE_BINDING_END"
        goal["criterion_revision"] = "revision-" * 100 + "REVISION_BINDING_END"
        verdict["criterion"].update(title=goal["title"], revision=goal["criterion_revision"])
        verdict["request_id"] = "request-" * 100 + "REQUEST_BINDING_END"
        verdict["verification_run_id"] = "verifier-" * 100 + "VERIFIER_BINDING_END"
        verdict["evidence"] = "proof evidence " * 100 + "EVIDENCE_BINDING_END"
    proof = {"state": "proof_proven", "verdict": verdict}
    goal["verification"] = {"completion": proof}
    response = {
        "goal": goal,
        "verification": {"goal_id": goal_id, "completion": proof},
    }
    expected_binding = {
        "goal_id": goal_id, "criterion_revision": goal["criterion_revision"],
        "request_id": verdict["request_id"], "verification_run_id": verdict["verification_run_id"],
    }
    fixtures = _keyboard_harness.overview_event_http_fixtures()
    fixtures[_keyboard_harness.PLANNING_PATH] = _keyboard_harness.planning_snapshot([goal])
    fixtures[_keyboard_harness.DASHBOARD_GOALS_PATH] = (200, {
        "generated_at": "2026-09-19T08:00:00Z",
        "tree": [{
            "id": goal_id, "title": goal["title"], "phase": "awaiting_confirmation",
            "priority": goal["priority"], "criterion_revision": goal["criterion_revision"],
            "metric": goal["metric"], "target_value": goal["target_value"],
            "measurement": {"state": "reported", "record": {
                "goal_id": goal_id, "criterion_revision": goal["criterion_revision"],
                "observed_value": "5", "evidence": "measurement evidence beyond first viewport " * 1000,
                "actor": "measurement-fixture", "recorded_at": "2026-09-19T08:00:00Z",
            }},
            "due_date": None, "task_count": 0, "task_done_count": 0,
            "stagnation_seconds": None, "tasks": [], "children": [],
        }],
    })
    read_count = 0
    posted: list[object] = []
    read_entered = threading.Event()
    release_read = threading.Event()
    submit_entered = threading.Event()
    release_submit = threading.Event()

    def read() -> _keyboard_harness.HttpResponse:
        nonlocal read_count
        read_count += 1
        read_entered.set()
        if not release_read.wait(timeout=15.0):
            return 500, {"error": "test did not release confirmation read"}
        return 200, response

    def submit(body: bytes) -> _keyboard_harness.HttpResponse:
        posted.append(json.loads(body))
        submit_entered.set()
        if not release_submit.wait(timeout=15.0):
            return 500, {"error": "test did not release the confirmation response"}
        expected = expected_binding
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
        fixtures[_keyboard_harness.PLANNING_PATH] = _keyboard_harness.planning_snapshot([confirmed_goal])
        return 200, confirmed

    fixtures[f"/api/v1/goals/confirmation?goal_id={goal_id}"] = read
    fixtures["/api/v1/goals/confirmation"] = _keyboard_harness.RequestHttpResponse(submit)

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        _keyboard_harness.resize_and_wait(
            process,
            master_fd,
            output,
            rows=24,
            columns=160,
            needle=b"MASC Dashboard",
            final_cursor=b"\x1b[?25l",
        )
        _keyboard_planning.open_loaded_planning(process, master_fd, output)
        # Keep the Goal visible when its phase changes to completed.
        for phase_filter in (b"completed", b"dropped", b"all"):
            _keyboard_harness.send_and_wait(process, master_fd, output, b"f", b"filter:" + phase_filter)
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\r", b"[a] Confirm proof")
        if not long_binding:
            _keyboard_harness.wait_for_output(process, master_fd, output, b"Actual: 5 (reported)", start=0, timeout=5.0)
        _keyboard_harness.write_all(master_fd, output, b"a")
        if not _keyboard_harness.wait_for_fixture_event(process, master_fd, output, read_entered, timeout=3.0):
            raise AssertionError("confirmation read never reached the server")
        try:
            # Scroll the long measurement while the proof request is held.
            # Its completion must bring the newly actionable binding into view.
            _keyboard_harness.press_and_settle(process, master_fd, output, b"jjjjjjjjjj")
            proof_start = len(output)
        finally:
            release_read.set()
        _keyboard_harness.wait_for_output(process, master_fd, output, b"CONFIRM THIS PROOF",
                          start=proof_start, timeout=5.0)
        _keyboard_harness.wait_for_output(process, master_fd, output, _keyboard_harness.FRAME_END,
                          start=_keyboard_harness.end_of_needle(output, b"CONFIRM THIS PROOF", proof_start), timeout=3.0)
        proof_frame = bytes(output[proof_start:])
        # send_and_wait ends at FRAME_END after this interaction's confirmation.
        # Replay only that returned frame, never historical terminal output.
        proof_screen = _keyboard_harness.screen_text(proof_frame)
        if long_binding:
            if b"EVIDENCE_BINDING_END" in proof_screen:
                raise AssertionError("long binding unexpectedly fits in the initial viewport")
            _keyboard_harness.send_and_wait(process, master_fd, output, b"a",
                            b"Read through the proof binding before confirming")
            if posted:
                raise AssertionError("unseen binding allowed completion")
            # A taller real frame shows the whole binding, including its end.
            _keyboard_harness.resize_and_wait(process, master_fd, output, rows=400, columns=160,
                              needle=b"EVIDENCE_BINDING_END", controls=(_keyboard_harness.FULL_REDRAW,))
            binding_screen = _keyboard_harness.screen_text(bytes(output))
            for tail in (b"TITLE_BINDING_END", b"REVISION_BINDING_END", b"REQUEST_BINDING_END",
                         b"VERIFIER_BINDING_END", b"EVIDENCE_BINDING_END"):
                if tail not in binding_screen:
                    raise AssertionError(f"expanded proof lost binding field: {tail!r}")
        else:
            for binding in (b"CONFIRM THIS PROOF", b"revision-1", b"request-1", b"Verifier run: run-1"):
                if binding not in proof_screen:
                    raise AssertionError(f"Long measurement hid the active proof binding: {binding!r}")
        if read_count != 1 or posted:
            raise AssertionError("first key must read the proof without posting")
        # Make the proof reader overflow, so its edges change real rows.
        _keyboard_harness.resize_and_wait(process, master_fd, output, rows=18, columns=80,
                          needle=b"CONFIRM THIS PROOF", final_cursor=b"\x1b[?25l")
        def reader_window():
            end = output.rfind(_keyboard_harness.FRAME_END)
            complete = bytes(output[:end + len(_keyboard_harness.FRAME_END)])
            match = re.search(rb"\[lines (\d+)-(\d+)/(\d+)\]", _keyboard_harness.screen_text(complete))
            if match is None:
                raise AssertionError("confirmation reader did not overflow")
            return tuple(int(value) for value in match.groups())
        first, last, total = reader_window()
        if first != 1 or last >= total:
            raise AssertionError("confirmation reader must start in an overflowing first window")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b[F", b"[lines ")
        end_first, end_last, end_total = reader_window()
        if end_first <= first or end_last != total or end_total != total:
            raise AssertionError("End did not reach the same proof document's last row")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b[H", b"CONFIRM THIS PROOF")
        if reader_window() != (first, last, total):
            raise AssertionError("Home did not return to the same inspected proof")
        if read_count != 1 or posted:
            raise AssertionError("reader edges must not reread or post the proof")
        # Submit from the overflowed last window, where metadata remains
        # scrollable even after the proof is replaced by a Sending row.
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b[F", b"[lines ")
        if reader_window()[0] <= 1 or reader_window()[1] != total:
            raise AssertionError("submission must start from the proof document's end")
        if replace_proof:
            verdict["verification_run_id"] = "run-2"
        needle = (
            b"confirmation proof changed" if replace_proof else b"reached its target"
        )
        try:
            submitting_frame = _keyboard_harness.send_and_wait(
                process, master_fd, output, b"a", b"Sending proof confirmation..."
            )
            if reader_window()[0] != 1:
                raise AssertionError("Sending state must reset the document to its first row")
            complete_end = output.rfind(_keyboard_harness.FRAME_END)
            header = next(row for row in _keyboard_harness.screen_text(bytes(output[:complete_end + len(_keyboard_harness.FRAME_END)])).splitlines()
                          if b"MASC Work" in row)
            if goal_id.encode() not in header or b"confirming" not in header:
                raise AssertionError(f"Sending header lost Goal identity or phase: {header!r}")
            if not _keyboard_harness.wait_for_fixture_event(
                process, master_fd, output, submit_entered, timeout=3.0
            ):
                raise AssertionError("confirmation POST never reached the server")
            # Repeated input and leaving/reopening the detail cannot unsend
            # the pending POST or permit a second request while it is held.
            _keyboard_harness.write_all(master_fd, output, b"aa")
            _keyboard_harness.send_and_wait(process, master_fd, output, b"\x1b", _keyboard_harness.PLANNING_LIST_HEADER)
            _keyboard_harness.send_and_wait(
                process, master_fd, output, b"\r", b"Sending proof confirmation..."
            )
            # Keep the existing result evidence at its original geometry;
            # the held in-flight assertions above exercised the short reader.
            _keyboard_harness.resize_and_wait(process, master_fd, output, rows=50, columns=160,
                              needle=b"Sending proof confirmation...", final_cursor=b"\x1b[?25l")
            result_start = len(output)
        finally:
            release_submit.set()
        _keyboard_harness.wait_for_output(
            process, master_fd, output, needle, start=result_start, timeout=5.0
        )
        _keyboard_harness.wait_for_output(
            process,
            master_fd,
            output,
            _keyboard_harness.FRAME_END,
            start=_keyboard_harness.end_of_needle(output, needle, result_start),
            timeout=3.0,
        )
        result_frame = bytes(output[result_start:])
        if read_count != 1 or len(posted) != 1:
            raise AssertionError(
                "second key must post once without reading a new proof"
            )
        if posted[0] != expected_binding:
            raise AssertionError(
                f"confirmation changed the displayed binding: {posted!r}"
            )
        print(
            "GOAL_CONFIRMATION_PTY_EVIDENCE "
            + json.dumps(
                {
                    "server": "controlled_http_fixture",
                    "proof_changed": replace_proof,
                    "long_binding": long_binding,
                    "get_requests": read_count,
                    "post_requests": posted,
                    "encoding": "base64",
                    "proof_frame": base64.b64encode(proof_frame).decode(),
                    "submitting_frame": base64.b64encode(submitting_frame).decode(),
                    "result_frame": base64.b64encode(result_frame).decode(),
                }
            )
        )
        os.write(master_fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Goal confirmation preserves the inspected proof"
        + (" when the server proof changes" if replace_proof else "")
        + (" after every long binding field becomes visible" if long_binding else ""),
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    for replaced in (False, True):
        run(os.path.abspath(sys.argv[1]), replace_proof=replaced)
    run(os.path.abspath(sys.argv[1]), replace_proof=False, long_binding=True)
    print("Goal confirmation key and HTTP wiring: PASS (3 scenarios)")
