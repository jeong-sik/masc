"""Workspace first-read failure has one verdict and its full cause."""

import os
import sys

import test_tui_keyboard_input as h



ERROR = b"repository load failed: HTTP 503: fixture repository unavailable"


def run(executable: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[h.REPOSITORIES_PATH] = (
        503, {"error": "fixture repository unavailable"}
    )

    def interact(process, fd, _slave, output, _base):
        h.tab_until(process, fd, output, b"MASC Workspace")
        h.resize_and_wait(
            process, fd, output, rows=30, columns=140,
            needle=b"MASC Workspace", controls=(h.FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        h.wait_for_output(process, fd, output, ERROR, start=0, timeout=10)
        screen = h.screen_text(bytes(output))
        if screen.count(ERROR) != 1:
            raise AssertionError(f"Workspace lost or repeated the cause: {screen!r}")
        if b"(load failed)" in screen:
            raise AssertionError(f"Workspace repeated the failure in its title: {screen!r}")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Workspace first read failure is shown once",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Workspace first read failure once: PASS")
