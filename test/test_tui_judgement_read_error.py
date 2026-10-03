"""Task Review, Task Verdicts and Fusion show each first-read cause once."""

import os
import sys

import tui_keyboard_approvals as _keyboard_approvals
import tui_keyboard_harness as _keyboard_harness




def run(executable: str) -> None:
    fixtures = _keyboard_harness.overview_event_http_fixtures()
    cases = (
        (_keyboard_approvals.VERIFICATION_QUEUE_PATH, b"verification load failed"),
        (_keyboard_approvals.HARNESS_HEALTH_PATH, b"harness load failed"),
        ("/api/v1/dashboard/fusion-runs", b"fusion runs load failed"),
    )
    for path, _ in cases:
        fixtures[path] = (503, {"error": "fixture judgement unavailable"})

    def interact(process, fd, _slave, output, _base):
        def check_cause(prefix: bytes, columns: int):
            cause = prefix + b": HTTP 503: fixture judgement unavailable"
            _keyboard_harness.wait_for_output(process, fd, output, cause, start=0, timeout=10)
            _keyboard_harness.resize_and_wait(
                process, fd, output, rows=30, columns=columns,
                needle=cause, controls=(_keyboard_harness.FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            screen = _keyboard_harness.screen_text(bytes(output))
            if screen.count(cause) != 1 or screen.count(b"load failed") != 1:
                raise AssertionError(f"{prefix!r} was repeated or lost: {screen!r}")

        _keyboard_harness.palette_go(process, fd, output, b"go work", b"MASC Work")
        _keyboard_harness.send_and_wait(process, fd, output, b"v", b"\xe2\x96\xb8Task Review")
        check_cause(b"verification load failed", 160)
        _keyboard_harness.send_and_wait(process, fd, output, b"v", b"\xe2\x96\xb8Task Verdicts")
        check_cause(b"harness load failed", 161)
        _keyboard_harness.palette_go(process, fd, output, b"go fusion", b"MASC Fusion")
        check_cause(b"fusion runs load failed", 162)
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Judgement first-read failures are shown once",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Judgement first-read failures once: PASS")
