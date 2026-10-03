"""Workspace first-read failure has one verdict and its full cause."""

import os
import sys

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_repositories as _keyboard_repositories



ERROR = b"repository load failed: HTTP 503: fixture repository unavailable"


def run(executable: str) -> None:
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    fixtures[_keyboard_repositories.REPOSITORIES_PATH] = (
        503, {"error": "fixture repository unavailable"}
    )

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.tab_until(process, fd, output, b"MASC Workspace")
        _keyboard_harness.wait_for_output(process, fd, output, ERROR, start=0, timeout=10)
        _keyboard_harness.resize_and_wait(
            process, fd, output, rows=30, columns=140,
            needle=ERROR, controls=(_keyboard_harness.FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        screen = _keyboard_harness.screen_text(bytes(output))
        if screen.count(ERROR) != 1:
            raise AssertionError(f"Workspace lost or repeated the cause: {screen!r}")
        if b"(load failed)" in screen:
            raise AssertionError(f"Workspace repeated the failure in its title: {screen!r}")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Workspace first read failure is shown once",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Workspace first read failure once: PASS")
