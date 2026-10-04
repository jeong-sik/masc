"""A pre-verdict queue read cannot revive an approved request."""

import json
import os
import sys
import threading

import tui_keyboard_approvals as _keyboard_approvals
import tui_keyboard_harness as _keyboard_harness



def run(executable):
    request = _keyboard_approvals.verification_request_row("task-901")
    request.update(request_id="vr-old", task_title="old submission")
    current = [request]
    gate = {
        "next": False,
        "requested": threading.Event(),
        "release": threading.Event(),
    }
    requests = []

    def queue_response():
        if gate["next"]:
            gate["next"] = False
            stale = _keyboard_approvals.verification_snapshot(list(current))
            gate["requested"].set()
            if not gate["release"].wait(timeout=15.0):
                return 504, {"error": "stale queue gate timed out"}
            return 200, stale
        return 200, _keyboard_approvals.verification_snapshot(list(current))

    def record_verdict(body):
        current.clear()
        return 200, {"ok": True, "message": "verdict recorded", "noop": False}

    def interact(process, master_fd, _slave_fd, output, _base_path):
        # Work owns Task Review; reach the destination through its palette
        # entry and wait for the request the verdict below will address.
        _keyboard_harness.palette_go(
            process, master_fd, output, b"go Task Review", b"old submission"
        )

        gate["next"] = True
        os.write(master_fd, b"r")
        if not _keyboard_harness.wait_for_fixture_event(
            process, master_fd, output, gate["requested"], timeout=3.0
        ):
            raise AssertionError("pre-verdict queue GET did not start")

        _keyboard_harness.send_and_wait(process, master_fd, output, b"a", b"armed: approve task-901")
        if any(path == _keyboard_approvals.VERIFICATION_VERDICT_PATH for path, _ in requests):
            raise AssertionError("first a sent a verdict")
        approve_start = len(output)
        os.write(master_fd, b"a")
        body = _keyboard_harness.wait_for_http_request(
            process, master_fd, output, requests, path=_keyboard_approvals.VERIFICATION_VERDICT_PATH
        )
        if json.loads(body) != {
            "task_id": "task-901",
            "verification_id": "vr-old",
            "verdict": "approve",
        }:
            raise AssertionError(f"verdict changed request identity: {body!r}")
        _keyboard_harness.wait_for_output(
            process, master_fd, output, b"not loaded yet",
            start=approve_start, timeout=5.0,
        )

        gate["release"].set()
        _keyboard_harness.wait_for_output(
            process, master_fd, output, b"awaiting 0", start=approve_start,
            timeout=5.0,
        )
        count_end = _keyboard_harness.end_of_needle(output, b"awaiting 0", approve_start)
        _keyboard_harness.wait_for_output(
            process, master_fd, output, _keyboard_harness.FRAME_END,
            start=count_end, timeout=3.0,
        )
        screen = _keyboard_harness.screen_text(bytes(output))
        if b"old submission" in screen or b"awaiting 1" in screen:
            raise AssertionError(f"stale GET revived the approved request: {screen!r}")
        print(
            "TUI_CAPTURE after_verdict_refresh "
            + json.dumps(screen.decode("utf-8", errors="replace")),
            flush=True,
        )
        os.write(master_fd, b"q")

    try:
        _keyboard_harness.run_terminal_scenario(
            executable,
            description="A stale queue GET is discarded after the verdict succeeds",
            interact=interact,
            http_fixtures={
                _keyboard_approvals.VERIFICATION_QUEUE_PATH: queue_response,
                _keyboard_approvals.VERIFICATION_VERDICT_PATH: _keyboard_harness.RequestHttpResponse(record_verdict),
            },
            http_requests=requests,
        )
    finally:
        gate["release"].set()


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("TUI verdict refresh: PASS")
