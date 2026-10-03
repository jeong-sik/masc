"""A second approval press belongs to the submission that the first armed."""

import json
import os
import sys

import tui_keyboard_approvals as _keyboard_approvals
import tui_keyboard_harness as _keyboard_harness



def run(executable):
    old = _keyboard_approvals.verification_request_row("task-901")
    old.update(request_id="vr-old", task_title="old submission")
    new = _keyboard_approvals.verification_request_row("task-901")
    new.update(request_id="vr-new", task_title="new submission")
    queue = {"current": old}
    requests = []

    def queue_response():
        return 200, _keyboard_approvals.verification_snapshot([queue["current"]])

    def verdict_bodies():
        return [
            body for path, body in requests
            if path == _keyboard_approvals.VERIFICATION_VERDICT_PATH
        ]

    def interact(process, master_fd, _slave_fd, output, _base_path):
        _keyboard_harness.palette_go(process, master_fd, output, b"go Task Review", b"old submission")
        _keyboard_harness.send_and_wait(
            process, master_fd, output, b"a",
            b"armed: approve task-901 -- same key again to send [vr-old]",
        )
        if verdict_bodies():
            raise AssertionError("first a sent a verdict")

        queue["current"] = new
        # No input between the two presses: any other key clears an armed
        # verdict already. The TUI's own cadence refresh must replace the row
        # while the first arm remains in place.
        redraw_start = len(output)
        _keyboard_harness.wait_for_output(
            process, master_fd, output, b"new submission",
            start=redraw_start, timeout=5.0,
        )
        title_end = _keyboard_harness.end_of_needle(output, b"new submission", redraw_start)
        _keyboard_harness.wait_for_output(
            process, master_fd, output, _keyboard_harness.FRAME_END,
            start=title_end, timeout=3.0,
        )
        refreshed = _keyboard_harness.screen_text(bytes(output))
        if b"changed or closed" not in refreshed or b"armed: approve" in refreshed:
            raise AssertionError(f"old approval arm survived a replaced request: {refreshed!r}")
        _keyboard_harness.send_and_wait(
            process, master_fd, output, b"a",
            b"armed: approve task-901 -- same key again to send [vr-new]",
        )
        if verdict_bodies():
            raise AssertionError("second a approved a different request for the same task")
        frame = _keyboard_harness.screen_text(bytes(output)).decode("utf-8", errors="replace")
        print("TUI_CAPTURE rearmed_completion " + json.dumps(frame), flush=True)

        os.write(master_fd, b"a")
        body = _keyboard_harness.wait_for_http_request(
            process, master_fd, output, requests, path=_keyboard_approvals.VERIFICATION_VERDICT_PATH
        )
        if json.loads(body) != {
            "task_id": "task-901",
            "verification_id": "vr-new",
            "verdict": "approve",
        }:
            raise AssertionError(f"third a posted a different request: {body!r}")
        os.write(master_fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="A replaced completion request needs two new approval presses",
        interact=interact,
        http_fixtures={
            _keyboard_approvals.VERIFICATION_QUEUE_PATH: queue_response,
            _keyboard_approvals.VERIFICATION_VERDICT_PATH: (
                200, {"ok": True, "message": "verdict recorded", "noop": False}
            ),
        },
        http_requests=requests,
        refresh=0.5,
    )

    detail_requests = []

    def detail_interaction(process, master_fd, _slave_fd, output, _base_path):
        _keyboard_harness.palette_go(process, master_fd, output, b"go Task Review", b"old submission")
        _keyboard_harness.send_and_wait(process, master_fd, output, b"\r", b"HOW TO READ THIS")
        _keyboard_harness.send_and_wait(
            process, master_fd, output, b"a",
            b"ARMED: a again to approve task-901 [vr-old]",
        )
        detail = _keyboard_harness.screen_text(bytes(output))
        if b"a twice: approve; x: reject with reason" not in detail:
            raise AssertionError(f"detail lost its persistent verdict guidance: {detail!r}")
        if any(path == _keyboard_approvals.VERIFICATION_VERDICT_PATH for path, _ in detail_requests):
            raise AssertionError("first a in detail sent a verdict")
        print(
            "TUI_CAPTURE armed_completion_detail "
            + json.dumps(detail.decode("utf-8", errors="replace")),
            flush=True,
        )
        os.write(master_fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Completion detail keeps the armed request and verdict keys visible",
        interact=detail_interaction,
        http_fixtures={
            _keyboard_approvals.VERIFICATION_QUEUE_PATH: (200, _keyboard_approvals.verification_snapshot([old])),
        },
        http_requests=detail_requests,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("TUI verdict request identity: PASS")
