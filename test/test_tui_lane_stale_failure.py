"""A stale standalone reading carries its read cause without a second verdict."""

import os
import re
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_loader.ml",
)

# The standalone heading's own clock, drawn only from a standalone lane read.
# A bare "observed " does not say that read landed: the Dashboard draws
# "Health: not observed" and its other unread rows before any read, and the
# wait searches from the start of the output, so it can match there and "r"
# can go out before the first lane reading it is meant to refresh.
LANES_OBSERVED = re.compile(
    rb"Standalone LLM lanes \xc2\xb7 observed \d{2}:\d{2}:\d{2}"
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
        fixtures = h.keeper_runtime_http_fixtures()
        fixtures[h.STANDALONE_LANES_PATH] = h.SequencedHttpResponse(
            [h.standalone_lanes_response(), failed_reading]
        )
        fixtures[h.RUNTIME_CONFIG_RAW_PATH] = (
            h.standalone_lane_runtime_config_response()
        )

        def interact(process, fd, _slave, output, _base_path):
            h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
            h.resize_and_wait(
                process, fd, output, rows=30, columns=160, needle=b"MASC Dashboard"
            )
            h.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
            h.wait_for_output(process, fd, output, LANES_OBSERVED, start=0, timeout=5)
            drawn = h.send_and_wait(process, fd, output, b"r", b"STALE")
            frame = h.unwrapped(h.screen_text(drawn))
            if b"STALE \xc2\xb7 standalone lanes load failed:" not in frame:
                raise AssertionError(f"stale reading lost the failure verdict: {frame!r}")
            if cause not in frame:
                raise AssertionError(f"stale reading lost the cause: {frame!r}")
            if frame.count(b"standalone lanes load failed:") != 1:
                raise AssertionError(f"stale reading repeated its verdict: {frame!r}")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
            os.write(fd, b"q")

        h.run_terminal_scenario(
            executable,
            description=f"stale standalone lane reading keeps one {kind} failure",
            interact=interact,
            http_fixtures=fixtures,
        )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("stale standalone lane failure: PASS")
