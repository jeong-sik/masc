"""The closed feed row on Activity puts its count where the live row puts it."""
import os
import re
import sys

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_observer as _keyboard_observer



CLOSED = b"feed: closed"
# What has to follow the state word: the count, with nothing between them. A
# word there ("closed after 3") turns the number into a duration to read, and
# the live row one frame earlier spends the same number as a count.
COUNT_AFTER_STATE = re.compile(rb"feed: closed (\d+)")


def feed_row(rows: dict[int, bytes], where: str) -> bytes:
    index = _keyboard_harness.screen_row_of(rows, CLOSED)
    if index < 0:
        raise AssertionError(f"{where} draws no closed feed row")
    return rows[index].rstrip()


def check(rows: dict[int, bytes], where: str) -> None:
    row = feed_row(rows, where)
    if not COUNT_AFTER_STATE.search(row):
        raise AssertionError(
            f"{where} does not put the count straight after the state word: {row!r}")


def run(executable: str) -> None:
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    # The feed has to answer before it has a count to carry: one refused while
    # opening reads "failed to open" with no number, so the scenario serves the
    # MCP handshake and a stream that delivers its frames and closes.
    observer = _keyboard_observer.observer_http_fixtures()
    fixtures["/mcp"] = observer["/mcp"]
    fixtures["/mcp?sse_kind=observer"] = observer["/mcp?sse_kind=observer"]

    def interact(process, fd, _slave, output, _base_path):
        _keyboard_harness.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        _keyboard_harness.palette_go(process, fd, output, b"go activity", b"MASC Activity")
        drawn = _keyboard_harness.resize_and_wait(process, fd, output, rows=30, columns=110,
                                  needle=CLOSED, controls=(_keyboard_harness.FULL_REDRAW,))
        check(_keyboard_harness.screen_rows(drawn), "the Activity status row")
        # The Activity row carries the reason as well, and the count belongs
        # between the state word and it -- not folded into the parenthesis.
        row = feed_row(_keyboard_harness.screen_rows(drawn), "the Activity status row")
        if b"(" not in row:
            raise AssertionError(f"the Activity row lost the reason: {row!r}")
        if row.index(b"(") < COUNT_AFTER_STATE.search(row).end():
            raise AssertionError(
                f"the Activity row puts the reason before the count: {row!r}")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable,
                            description="closed feed rows name their count",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("the closed feed rows count events: PASS")
