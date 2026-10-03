"""A failed Config source read has one visible cause on both TUI panes."""

import os
import sys

import test_tui_keyboard_input as h



ERROR_PREFIX = b"runtime config load failed: fetch:"
ERROR_CAUSE = ERROR_PREFIX + b" HTTP 503: fixture config unavailable"


def assert_one_cause(output: bytearray, pane: str) -> None:
    screen = h.screen_text(bytes(output))
    if screen.count(ERROR_PREFIX) != 1 or screen.count(ERROR_CAUSE) != 1:
        raise AssertionError(f"{pane} did not show one Config cause: {screen!r}")
    if b"(load failed)" in screen or b"Read failed:" in screen:
        raise AssertionError(f"{pane} repeated the Config failure: {screen!r}")


def run(executable: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[h.RUNTIME_CONFIG_RAW_PATH] = (
        503, {"error": "fixture config unavailable"}
    )

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go System / runtime.toml", b"MASC System")
        h.wait_for_output(process, fd, output, ERROR_PREFIX, start=0, timeout=10)
        h.resize_and_wait(process, fd, output, rows=30, columns=131,
                          needle=ERROR_PREFIX, controls=(h.FULL_REDRAW,),
                          final_cursor=b"\x1b[?25l")
        assert_one_cause(output, "source")
        h.send_and_wait(process, fd, output, b"v", b"runtime.toml status")
        assert_one_cause(output, "status")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Config first read failure is shown once",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Config first read failure once: PASS")
