"""A failed Config source read has one visible cause on both TUI panes."""

import os
import sys

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_runtime as _keyboard_runtime



ERROR_PREFIX = b"runtime config load failed: fetch:"
ERROR_CAUSE = ERROR_PREFIX + b" HTTP 503: fixture config unavailable"


def assert_one_cause(output: bytearray, pane: str) -> None:
    screen = _keyboard_harness.screen_text(bytes(output))
    if screen.count(ERROR_PREFIX) != 1 or screen.count(ERROR_CAUSE) != 1:
        raise AssertionError(f"{pane} did not show one Config cause: {screen!r}")
    if b"(load failed)" in screen or b"Read failed:" in screen:
        raise AssertionError(f"{pane} repeated the Config failure: {screen!r}")


def run(executable: str) -> None:
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    fixtures[_keyboard_runtime.RUNTIME_CONFIG_RAW_PATH] = (
        503, {"error": "fixture config unavailable"}
    )

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        _keyboard_harness.palette_go(process, fd, output, b"go System / runtime.toml", b"MASC System")
        _keyboard_harness.wait_for_output(process, fd, output, ERROR_PREFIX, start=0, timeout=10)
        _keyboard_harness.resize_and_wait(process, fd, output, rows=30, columns=131,
                          needle=ERROR_PREFIX, controls=(_keyboard_harness.FULL_REDRAW,),
                          final_cursor=b"\x1b[?25l")
        assert_one_cause(output, "source")
        _keyboard_harness.send_and_wait(process, fd, output, b"v", b"runtime.toml status")
        assert_one_cause(output, "status")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Config first read failure is shown once",
        interact=interact,
        http_fixtures=fixtures,
    )


def run_invalid_model_projection(executable: str) -> None:
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    config = _keyboard_runtime.runtime_config_read_metadata()
    config["validation"]["valid"] = False
    config.update(path="/fixture/runtime.toml",
                  source_text='unsupported_config_key = "operator-repair-marker"\n')
    fixtures[_keyboard_runtime.RUNTIME_CONFIG_RAW_PATH] = (200, config)

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.palette_go(process, fd, output, b"go System / runtime.toml", b"MASC System")
        _keyboard_harness.wait_for_output(process, fd, output, b"operator-repair-marker", start=0, timeout=5)
        _keyboard_harness.send_and_wait(process, fd, output, b"p", b"MASC Models")
        _keyboard_harness.drain_until_quiet(process, fd, output)
        models = _keyboard_harness.screen_text(bytes(output))
        if b"unsupported_config_key" not in models or b"operator-repair-marker" in models:
            raise AssertionError("Models did not expose its separate typed projection failure")
        _keyboard_harness.palette_go(process, fd, output, b"go System / runtime.toml", b"operator-repair-marker")
        if b"operator-repair-marker" not in _keyboard_harness.screen_text(bytes(output)):
            raise AssertionError("Models parse failure hid the successfully read raw source")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable,
        description="Invalid model projection preserves repairable Config source",
        interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    run_invalid_model_projection(os.path.abspath(sys.argv[1]))
    print("Config first read failure once: PASS")
