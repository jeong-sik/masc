"""A stale standalone reading carries its loader cause without a second verdict."""

import os
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
    "bin/masc_tui_loader.ml",
)

CAUSE = b"synthetic lane gateway unavailable"


def run(executable: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    reading = h.SequencedHttpResponse(
        [
            h.standalone_lanes_response(),
            (503, {"error": CAUSE.decode()}),
        ]
    )
    fixtures[h.STANDALONE_LANES_PATH] = reading
    fixtures[h.RUNTIME_CONFIG_RAW_PATH] = h.standalone_lane_runtime_config_response()

    def interact(process, fd, _slave, output, _base_path):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.resize_and_wait(
            process, fd, output, rows=30, columns=160, needle=b"MASC Overview"
        )
        h.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        h.wait_for_output(process, fd, output, b"observed ", start=0, timeout=5)
        drawn = h.send_and_wait(process, fd, output, b"r", b"STALE")
        frame = h.unwrapped(h.screen_text(drawn))
        if b"STALE \xc2\xb7 standalone lanes load failed:" not in frame:
            raise AssertionError(f"stale reading lost the loader verdict: {frame!r}")
        if CAUSE not in frame:
            raise AssertionError(f"stale reading lost the cause: {frame!r}")
        if b"refresh failed: standalone lanes load failed:" in frame:
            raise AssertionError(f"stale reading repeated its verdict: {frame!r}")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Overview")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="stale standalone lane reading keeps one failure verdict",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("stale standalone lane failure: PASS")
