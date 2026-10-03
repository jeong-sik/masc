"""The Activity title's dot goes when the tab strip it separates goes."""
import os
import re
import sys

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_observer as _keyboard_observer



TITLE = b"MASC Activity"
# A dot with nothing on its left: the row ran out of width, the strip drew
# nothing, and the separator that belonged to it stayed behind.
ORPHANED = re.compile(rb"MASC Activity\s+\xc2\xb7")
# The separator doing its job: the last tab, the dot, then the reading.
SEPARATED = re.compile(rb"Logs\s+\xc2\xb7\s+\(")
# The feed's count, which the title draws only once the feed has answered.
# Before that it reads "(not loaded)", which carries no "rows" at any width.
# "Health: " no longer says the first read landed: the Dashboard draws
# "Health: not observed" before any read, so the palette can open Activity,
# and both widths can be measured, before the feed has opened.
COUNTED = re.compile(rb"\(\d+ rows? \xc2\xb7 \d+ events? held\)")


def title_row(rows: dict[int, bytes], columns: int) -> bytes:
    index = _keyboard_harness.screen_row_of(rows, TITLE)
    if index < 0:
        raise AssertionError(f"at {columns} columns Activity drew no title")
    return rows[index].rstrip()


def run(executable: str) -> None:
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    # A feed that answers and closes empty, so the title holds a count. One
    # refused while opening reads "(load failed)" instead, and the reading this
    # scenario measures across widths would be a different one.
    fixtures["/mcp"] = _keyboard_observer.observer_http_fixtures()["/mcp"]
    fixtures["/mcp?sse_kind=observer"] = _keyboard_harness.RawHttpResponse(
        200, b"", content_type="text/event-stream")

    def interact(process, fd, _slave, output, _base_path):
        _keyboard_harness.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        _keyboard_harness.palette_go(process, fd, output, b"go activity", TITLE)
        _keyboard_harness.wait_for_output(process, fd, output, COUNTED, start=0, timeout=10)

        # Wide: the strip draws, and the dot after it separates the tabs from
        # the reading the row holds.
        drawn = _keyboard_harness.resize_and_wait(process, fd, output, rows=22, columns=110,
                                  needle=TITLE, controls=(_keyboard_harness.FULL_REDRAW,))
        row = title_row(_keyboard_harness.screen_rows(drawn), 110)
        for needle in (b"Events", b"Logs"):
            if needle not in row:
                raise AssertionError(
                    f"at 110 columns the title lost {needle!r}: {row!r}")
        # Between the last tab and the reading, not just anywhere on the row:
        # the reading itself spells "(0 rows \xc2\xb7 0 events held)", so a dot
        # somewhere is no evidence that the separator is there.
        if not SEPARATED.search(row):
            raise AssertionError(
                f"at 110 columns the strip and the reading are not separated: "
                f"{row!r}")

        # Narrow: the strip has no room at all. The dot goes with it.
        drawn = _keyboard_harness.resize_and_wait(process, fd, output, rows=22, columns=66,
                                  needle=TITLE, controls=(_keyboard_harness.FULL_REDRAW,))
        row = title_row(_keyboard_harness.screen_rows(drawn), 66)
        if b"Events" in row:
            raise AssertionError(
                f"at 66 columns the strip still had room, so this scenario "
                f"proves nothing: {row!r}")
        if ORPHANED.search(row):
            raise AssertionError(
                f"at 66 columns the dot outlived the strip it separates: {row!r}")
        # And the reading the dot used to introduce is still there.
        if b"rows" not in row:
            raise AssertionError(f"at 66 columns the title lost its reading: {row!r}")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable,
                            description="Activity title across widths",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("the Activity dot belongs to its strip: PASS")
