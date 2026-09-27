"""Activity Logs first-read failure has one verdict and its full cause."""

import os
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui_render.ml",)

ERROR = b"system logs load failed: HTTP 503: fixture logs unavailable"
LOGS_PATH = "/api/v1/dashboard/logs?limit=300"


def run(executable: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[LOGS_PATH] = (503, {"error": "fixture logs unavailable"})

    def interact(process, fd, _slave, output, _base):
        h.tab_until(process, fd, output, b"MASC Activity")
        h.send_and_wait(process, fd, output, b"2", b"\xe2\x96\xb8Logs")
        h.wait_for_output(process, fd, output, ERROR, start=0, timeout=10)
        h.resize_and_wait(
            process, fd, output, rows=30, columns=140,
            needle=ERROR, controls=(h.FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        screen = h.screen_text(bytes(output))
        if screen.count(ERROR) != 1:
            raise AssertionError(f"Activity Logs lost or repeated the cause: {screen!r}")
        if b"(load failed)" in screen:
            raise AssertionError(f"Activity Logs repeated the title verdict: {screen!r}")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Activity Logs first read failure is shown once",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Activity Logs first read failure once: PASS")
