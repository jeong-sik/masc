"""Task Review, Task Verdicts and Fusion show each first-read cause once."""

import os
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui_render.ml",)


def run(executable: str) -> None:
    fixtures = h.overview_event_http_fixtures()
    cases = (
        (h.VERIFICATION_QUEUE_PATH, b"verification load failed"),
        (h.HARNESS_HEALTH_PATH, b"harness load failed"),
        ("/api/v1/dashboard/fusion-runs", b"fusion runs load failed"),
    )
    for path, _ in cases:
        fixtures[path] = (503, {"error": "fixture judgement unavailable"})

    def interact(process, fd, _slave, output, _base):
        def check_cause(prefix: bytes, columns: int):
            cause = prefix + b": HTTP 503: fixture judgement unavailable"
            h.wait_for_output(process, fd, output, cause, start=0, timeout=10)
            h.resize_and_wait(
                process, fd, output, rows=30, columns=columns,
                needle=cause, controls=(h.FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            screen = h.screen_text(bytes(output))
            if screen.count(cause) != 1 or screen.count(b"load failed") != 1:
                raise AssertionError(f"{prefix!r} was repeated or lost: {screen!r}")

        h.palette_go(process, fd, output, b"go planning", b"MASC Planning")
        h.send_and_wait(process, fd, output, b"v", b"\xe2\x96\xb8Task Review")
        check_cause(b"verification load failed", 160)
        h.send_and_wait(process, fd, output, b"v", b"\xe2\x96\xb8Task Verdicts")
        check_cause(b"harness load failed", 161)
        h.palette_go(process, fd, output, b"go fusion", b"MASC Fusion")
        check_cause(b"fusion runs load failed", 162)
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Judgement first-read failures are shown once",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Judgement first-read failures once: PASS")
