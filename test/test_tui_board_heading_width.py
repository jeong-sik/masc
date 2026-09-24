"""The Board's two heading rows drop their tail rather than cut it."""
import os
import sys
import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs
# a suite when a pull request changes a path the suite names, so without this
# a change to the drawn text below reaches main with no scenario run. Both
# rows are built in masc_tui_render.ml.
SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
)

SORT_ROW = b"Sort [s]:"
HEARTH_ROW = b"f/F:next/previous"
# What each row carries only when it carries it whole. A key hint and the
# clause that finishes a sentence are both atomic: "H:choo" names no key and
# "f narrows once" stops before the condition.
SORT_TAIL = b"\xc2\xb7 H:choose hearth"
HEARTH_TAIL = b"\xe2\x80\x94 f narrows once they are"
# Every mark either tail could leave behind if it were cut instead of dropped.
SORT_MARK = b"H:"
HEARTH_MARK = b"\xe2\x80\x94"
CUT = b"\xe2\x80\xa6"


def row_carrying(rows: dict[int, bytes], needle: bytes) -> bytes:
    row = h.screen_row_of(rows, needle)
    if row < 0:
        raise AssertionError(f"no row carries {needle!r}")
    return rows[row].rstrip()


def check_row(rows: dict[int, bytes], columns: int, needle: bytes,
              tail: bytes, mark: bytes) -> bool:
    text = row_carrying(rows, needle)
    if CUT in text:
        raise AssertionError(
            f"at {columns} columns the row carrying {needle!r} was cut: {text!r}")
    whole = tail in text
    if not whole and mark in text:
        raise AssertionError(
            f"at {columns} columns the row carrying {needle!r} kept part of its "
            f"tail: {text!r}")
    return whole


def run(executable: str) -> None:
    fixtures = h.overview_event_http_fixtures()
    post = h.board_selection_post("heading", "Heading width", "Short body")
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": [post]})

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        # The scenario opens at a hundred columns, and resizing to the size
        # the terminal already has sends no SIGWINCH -- so that width is read
        # off the screen as drawn rather than asked for again.
        carried = {}

        def measure(columns: int, rows: dict[int, bytes]) -> None:
            carried[columns] = (
                check_row(rows, columns, SORT_ROW, SORT_TAIL, SORT_MARK),
                check_row(rows, columns, HEARTH_ROW, HEARTH_TAIL, HEARTH_MARK),
            )

        h.read_available(fd, output)
        measure(100, h.screen_rows(bytes(output)))
        # Widest first, so the widths that drop a tail are measured after a
        # screen that was seen carrying it. A tail nobody ever draws would
        # otherwise pass every narrow case.
        for columns in (72, 68, 67, 66, 62, 58):
            drawn = h.resize_and_wait(process, fd, output, rows=30,
                                      columns=columns, needle=SORT_ROW,
                                      controls=(h.FULL_REDRAW,))
            measure(columns, h.screen_rows(drawn))
        if carried[100] != (True, True):
            raise AssertionError(
                f"a hundred columns held neither tail whole: {carried[100]}")
        if carried[58] != (False, False):
            raise AssertionError(
                f"fifty-eight columns still drew a tail: {carried[58]}")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
                            description="Board heading rows across widths",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Board heading tails are whole or absent: PASS")
