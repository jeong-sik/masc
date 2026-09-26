"""Runtime first-read failure has one verdict across its title and fields."""

import os
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui_render.ml",)

ERROR = b"runtime resolved load failed: HTTP 503: fixture resolved unavailable"


def run(executable: str) -> None:
    fixtures, _initial_probe, _force_probe = h.runtime_http_fixtures()
    fixtures[h.RUNTIME_PROBE_PATH] = h.runtime_probe_response(fresh=False)
    fixtures[h.RUNTIME_RESOLVED_PATH] = (
        503, {"error": "fixture resolved unavailable"}
    )

    def interact(process, fd, _slave, output, _base):
        h.tab_until(process, fd, output, b"MASC Config")
        h.send_and_wait(process, fd, output, b"9", b"MASC Config / Runtime")
        h.wait_for_output(process, fd, output, ERROR, start=0, timeout=10)
        h.resize_and_wait(
            process, fd, output, rows=30, columns=160,
            needle=ERROR, controls=(h.FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        screen = h.screen_text(bytes(output))
        if screen.count(ERROR) != 1 or screen.count(b"load failed") != 1:
            raise AssertionError(f"Runtime repeated or lost the cause: {screen!r}")
        for field in (b"[runtime].default", b"media_failover"):
            if field not in screen:
                raise AssertionError(f"Runtime hid {field!r} on failure: {screen!r}")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Runtime resolved first read failure is shown once",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Runtime resolved first read failure once: PASS")
