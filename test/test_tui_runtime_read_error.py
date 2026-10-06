"""Runtime first-read failure has one verdict across its title and fields."""

import os
import sys

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_runtime as _keyboard_runtime



ERROR = b"runtime resolved load failed: HTTP 503: fixture resolved unavailable"


def run(executable: str) -> None:
    fixtures, _initial_probe, _force_probe = _keyboard_runtime.runtime_http_fixtures()
    fixtures[_keyboard_runtime.RUNTIME_PROBE_PATH] = _keyboard_runtime.runtime_probe_response(fresh=False)
    fixtures[_keyboard_harness.RUNTIME_RESOLVED_PATH] = (
        503, {"error": "fixture resolved unavailable"}
    )

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.tab_until(process, fd, output, b"MASC System")
        _keyboard_harness.send_and_wait(process, fd, output, b"9", b"MASC System / Runtime")
        _keyboard_harness.wait_for_output(process, fd, output, ERROR, start=0, timeout=10)
        _keyboard_harness.resize_and_wait(
            process, fd, output, rows=30, columns=160,
            needle=ERROR, controls=(_keyboard_harness.FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        screen = _keyboard_harness.screen_text(bytes(output))
        if screen.count(ERROR) != 1 or screen.count(b"load failed") != 1:
            raise AssertionError(f"Runtime repeated or lost the cause: {screen!r}")
        # #40824 moved the default-route row to runtime_default_route_lines
        # (bin/masc_tui_types.ml:11523): it draws the route with an "f replaces"
        # hint when a route is observed, and "not observed" when the read
        # failed. So the f hint is absent here, and the row itself is the
        # unavailable marker.
        default_rows = [row for row in screen.splitlines() if b"[runtime].default" in row]
        if len(default_rows) != 1 or b"not observed" not in default_rows[0]:
            raise AssertionError(
                f"Runtime did not mark the default route unavailable: {screen!r}"
            )
        if b"f replaces" in screen:
            raise AssertionError(f"Runtime drew the f hint without a route: {screen!r}")
        media_rows = [row for row in screen.splitlines() if b"m edits it" in row]
        if len(media_rows) != 1 or b"\xe2\x80\x94" not in media_rows[0]:
            raise AssertionError(
                f"Runtime did not mark b'm edits it' unavailable: {screen!r}"
            )
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Runtime resolved first read failure is shown once",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Runtime resolved first read failure once: PASS")
