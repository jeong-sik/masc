"""The Activity title's dot goes when the tab strip it separates goes."""
import os
import re
import sys
import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs a
# suite when a pull request changes a path the suite names.
SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
)

TITLE = b"MASC Activity"
# A dot with nothing on its left: the row ran out of width, the strip drew
# nothing, and the separator that belonged to it stayed behind.
ORPHANED = re.compile(rb"MASC Activity\s+\xc2\xb7")
# The separator doing its job: the last tab, the dot, then the reading.
SEPARATED = re.compile(rb"Logs\s+\xc2\xb7\s+\(")


def title_row(rows: dict[int, bytes], columns: int) -> bytes:
    index = h.screen_row_of(rows, TITLE)
    if index < 0:
        raise AssertionError(f"at {columns} columns Activity drew no title")
    return rows[index].rstrip()


def run(executable: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()

    def interact(process, fd, _slave, output, _base_path):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go activity", TITLE)

        # Wide: the strip draws, and the dot after it separates the tabs from
        # the reading the row holds.
        drawn = h.resize_and_wait(process, fd, output, rows=22, columns=110,
                                  needle=TITLE, controls=(h.FULL_REDRAW,))
        row = title_row(h.screen_rows(drawn), 110)
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
        drawn = h.resize_and_wait(process, fd, output, rows=22, columns=66,
                                  needle=TITLE, controls=(h.FULL_REDRAW,))
        row = title_row(h.screen_rows(drawn), 66)
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
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Overview")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
                            description="Activity title across widths",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("the Activity dot belongs to its strip: PASS")
