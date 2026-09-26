"""A second approval press belongs to the submission that the first armed."""

import json
import os
import sys

import test_tui_keyboard_input as h


SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_types.ml",
)


def run(executable):
    old = h.verification_request_row("task-901")
    old.update(request_id="vr-old", task_title="old submission")
    new = h.verification_request_row("task-901")
    new.update(request_id="vr-new", task_title="new submission")
    queue = {"current": old}
    requests = []

    def queue_response():
        return 200, h.verification_snapshot([queue["current"]])

    def verdict_bodies():
        return [
            body for path, body in requests
            if path == h.VERIFICATION_VERDICT_PATH
        ]

    def interact(process, master_fd, _slave_fd, output, _base_path):
        h.tab_until(process, master_fd, output, b"MASC Planning")
        h.send_and_wait(process, master_fd, output, b"v", b"Task Review")
        h.wait_for_output(
            process, master_fd, output, b"old submission", start=0, timeout=3.0
        )
        h.send_and_wait(
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
        h.wait_for_output(
            process, master_fd, output, b"new submission",
            start=redraw_start, timeout=5.0,
        )
        title_end = h.end_of_needle(output, b"new submission", redraw_start)
        h.wait_for_output(
            process, master_fd, output, h.FRAME_END,
            start=title_end, timeout=3.0,
        )
        refreshed = h.screen_text(bytes(output))
        if b"changed or closed" not in refreshed or b"armed: approve" in refreshed:
            raise AssertionError(f"old approval arm survived a replaced request: {refreshed!r}")
        h.send_and_wait(
            process, master_fd, output, b"a",
            b"armed: approve task-901 -- same key again to send [vr-new]",
        )
        if verdict_bodies():
            raise AssertionError("second a approved a different request for the same task")
        frame = h.screen_text(bytes(output)).decode("utf-8", errors="replace")
        print("TUI_CAPTURE rearmed_completion " + json.dumps(frame), flush=True)

        os.write(master_fd, b"a")
        body = h.wait_for_http_request(
            process, master_fd, output, requests, path=h.VERIFICATION_VERDICT_PATH
        )
        if json.loads(body) != {
            "task_id": "task-901",
            "verification_id": "vr-new",
            "verdict": "approve",
        }:
            raise AssertionError(f"third a posted a different request: {body!r}")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="A replaced completion request needs two new approval presses",
        interact=interact,
        http_fixtures={
            h.VERIFICATION_QUEUE_PATH: queue_response,
            h.VERIFICATION_VERDICT_PATH: (
                200, {"ok": True, "message": "verdict recorded", "noop": False}
            ),
        },
        http_requests=requests,
        refresh=0.5,
    )

    detail_requests = []

    def detail_interaction(process, master_fd, _slave_fd, output, _base_path):
        h.tab_until(process, master_fd, output, b"MASC Planning")
        h.send_and_wait(process, master_fd, output, b"v", b"Task Review")
        h.wait_for_output(
            process, master_fd, output, b"old submission", start=0, timeout=3.0
        )
        h.send_and_wait(process, master_fd, output, b"\r", b"HOW TO READ THIS")
        h.send_and_wait(
            process, master_fd, output, b"a",
            b"ARMED: a again to approve task-901 [vr-old]",
        )
        detail = h.screen_text(bytes(output))
        if b"a twice: approve; x: reject with reason" not in detail:
            raise AssertionError(f"detail lost its persistent verdict guidance: {detail!r}")
        if any(path == h.VERIFICATION_VERDICT_PATH for path, _ in detail_requests):
            raise AssertionError("first a in detail sent a verdict")
        print(
            "TUI_CAPTURE armed_completion_detail "
            + json.dumps(detail.decode("utf-8", errors="replace")),
            flush=True,
        )
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Completion detail keeps the armed request and verdict keys visible",
        interact=detail_interaction,
        http_fixtures={
            h.VERIFICATION_QUEUE_PATH: (200, h.verification_snapshot([old])),
        },
        http_requests=detail_requests,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("TUI verdict request identity: PASS")
