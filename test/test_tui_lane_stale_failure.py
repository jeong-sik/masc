"""A stale standalone reading carries its read cause without a second verdict."""

import os
import re
import sys

import tui_keyboard_chat as _keyboard_chat
import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_keepers as _keyboard_keepers
import tui_keyboard_runtime as _keyboard_runtime



# The standalone heading's own clock, drawn only from a standalone lane read.
# A bare "observed " does not say that read landed: the Dashboard draws
# "Health: not observed" and its other unread rows before any read, and the
# wait searches from the start of the output, so it can match there and "r"
# can go out before the first lane reading it is meant to refresh.
LANES_OBSERVED = re.compile(
    rb"Lanes \xc2\xb7 observed \d{2}:\d{2}:\d{2}"
)

def run(executable: str) -> None:
    for kind, failed_reading, cause in (
        (
            "HTTP",
            (503, {"error": "synthetic lane gateway unavailable"}),
            b"synthetic lane gateway unavailable",
        ),
        ("decode", (200, {}), b"schema"),
    ):
        fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
        fixtures[_keyboard_keepers.STANDALONE_LANES_PATH] = _keyboard_harness.SequencedHttpResponse(
            [_keyboard_keepers.standalone_lanes_response(), failed_reading]
        )
        fixtures[_keyboard_runtime.RUNTIME_CONFIG_RAW_PATH] = (
            _keyboard_keepers.standalone_lane_runtime_config_response()
        )

        def interact(process, fd, _slave, output, _base_path):
            _keyboard_harness.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
            _keyboard_harness.resize_and_wait(
                process, fd, output, rows=30, columns=160, needle=b"MASC Dashboard"
            )
            _keyboard_harness.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
            _keyboard_harness.wait_for_output(process, fd, output, LANES_OBSERVED, start=0, timeout=5)
            drawn = _keyboard_harness.send_and_wait(process, fd, output, b"r", b"STALE")
            frame = _keyboard_chat.unwrapped(_keyboard_harness.screen_text(drawn))
            if b"STALE \xc2\xb7 lanes load failed:" not in frame:
                raise AssertionError(f"stale reading lost the failure verdict: {frame!r}")
            if cause not in frame:
                raise AssertionError(f"stale reading lost the cause: {frame!r}")
            if frame.count(b"lanes load failed:") != 1:
                raise AssertionError(f"stale reading repeated its verdict: {frame!r}")
            _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
            os.write(fd, b"q")

        _keyboard_harness.run_terminal_scenario(
            executable,
            description=f"stale standalone lane reading keeps one {kind} failure",
            interact=interact,
            http_fixtures=fixtures,
        )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("stale standalone lane failure: PASS")
