"""The Board's hearth census row budgets what it draws."""
import os
import sys
import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs a
# suite when a pull request changes a path the suite names. The frame and the
# acting pane draw nothing the scenario waits for; the boundary widths below
# are built from the frame's margin and the pane's narrow width.
SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
    "bin/masc_tui_frame.ml",
    "bin/masc_tui_acting_pane.ml",
)

# No trailing space: the row draws the word dimmed, so a reset sits between
# "hearths" and the space after it and a needle carrying that space matches
# nothing in the raw output.
CENSUS_ROW = b"hearths"
TOTAL = b"198 posts"
DROPPED = b"+"
CUT = b"\xe2\x80\xa6"

# Eight hearths whose names and counts, laid out with the separator the row
# draws, run past the first three widths this scenario uses. The row has to
# drop the ones that do not fit and still end on the total.
#
# One name arrives with a control byte in it. The row draws the byte as the
# four-cell escape "\x07" (Tui_decode.sanitize_terminal_text), so on screen
# that name takes eight cells, and measured as it arrived it takes four.
HEARTHS = [
    ("verification", 91),
    ("research", 58),
    ("code-review", 19),
    ("ops", 17),
    ("ch\x07ik", 8),
    ("rondo", 3),
    ("general", 1),
    ("glossary-maniac", 1),
]
# Each hearth as the row spells it.
ENTRIES = [
    f"{name} {count}".replace("\x07", "\\x07").encode()
    for name, count in HEARTHS
]

# The row with every hearth on it and nothing dropped: the lead "  hearths "
# (10 cells), the entries with a five-cell "  ·  " between each two (124; the
# middle dot is one cell) and the tail "   198 posts" (12). 146 cells.
SEPARATOR_CELLS = 5
FULL_ROW_CELLS = (
    len("  hearths ")
    + sum(len(entry) for entry in ENTRIES)
    + SEPARATOR_CELLS * (len(ENTRIES) - 1)
    + len(b"   " + TOTAL)
)

# The Board lays the row out in the frame's inner width, four cells short of
# the columns the surface gets (Masc_tui_frame.inner_width). From
# Masc_tui_acting_pane.threshold_cols (132) the acting pane takes its narrow
# width off the terminal first, and the widths built here are all past that.
FRAME_MARGIN_CELLS = 4


def columns_for_inner_width(cells: int) -> int:
    return cells + FRAME_MARGIN_CELLS + h.ACTING_PANE_NARROW_COLUMNS


def census_row(rows: dict[int, bytes], columns: int) -> bytes:
    index = h.screen_row_of(rows, CENSUS_ROW)
    if index < 0:
        raise AssertionError(f"at {columns} columns the board drew no census row")
    return rows[index].rstrip()


def census_span(row: bytes, columns: int) -> bytes:
    """The row from its label through its total. The acting pane draws beside
    the frame on the same terminal row, so whatever follows the total is the
    pane's. A row cut at the frame's edge loses its total first."""
    start = row.find(CENSUS_ROW)
    end = row.find(TOTAL, start)
    if end < 0:
        raise AssertionError(
            f"at {columns} columns the census row lost its total: {row!r}")
    return row[start:end + len(TOTAL)]


def run(executable: str) -> None:
    fixtures = h.overview_event_http_fixtures()
    post = h.board_selection_post("census", "Census width", "Short body")
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": [post]})
    fixtures["/api/v1/board/hearths"] = (
        200,
        {"hearths": [{"name": name, "count": count} for name, count in HEARTHS]},
    )

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"cluster-a", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        # Never 100: the scenario opens there, and resizing to the width the
        # terminal already has sends no SIGWINCH, so nothing redraws.
        for columns in (96, 130, 160):
            drawn = h.resize_and_wait(process, fd, output, rows=30,
                                      columns=columns, needle=CENSUS_ROW,
                                      controls=(h.FULL_REDRAW,))
            row = census_row(h.screen_rows(drawn), columns)
            if CUT in row:
                raise AssertionError(
                    f"at {columns} columns the census row was cut: {row!r}")
            if TOTAL not in row:
                raise AssertionError(
                    f"at {columns} columns the census row lost its total: "
                    f"{row!r}")
            # And the row is under pressure at this width: if every hearth fit
            # there would be nothing for the budget to get wrong, and this
            # scenario would pass whatever the budget said.
            if DROPPED not in row:
                raise AssertionError(
                    f"at {columns} columns every hearth fit, so this scenario "
                    f"proves nothing: {row!r}")
        # Every hearth fits in FULL_ROW_CELLS, so the row draws all of them
        # and no "+N". A row that set the note's room aside before filling
        # would drop glossary-maniac here and draw "+1". One cell less and
        # the last hearth has no room: it goes, the row says "+1", and the
        # row still ends on its total. A row that measured the control byte
        # as it arrived would count four cells too few, keep all eight at
        # that width and run past the frame.
        #
        # The wait is for the total, not the label: the row is read through
        # its last cell before it is checked, and a row cut at the frame's
        # edge never draws its total.
        for inner, expected, note in (
            (FULL_ROW_CELLS, ENTRIES, None),
            (FULL_ROW_CELLS - 1, ENTRIES[:-1], b"+1"),
        ):
            columns = columns_for_inner_width(inner)
            drawn = h.resize_and_wait(process, fd, output, rows=30,
                                      columns=columns, needle=TOTAL,
                                      controls=(h.FULL_REDRAW,))
            span = census_span(census_row(h.screen_rows(drawn), columns),
                               columns)
            shown = [entry for entry in ENTRIES if entry in span]
            if shown != expected:
                raise AssertionError(
                    f"at {inner} inner cells the census row drew {shown!r}, "
                    f"not {expected!r}: {span!r}")
            if note is None and DROPPED in span:
                raise AssertionError(
                    f"at {inner} inner cells every hearth fits, but the row "
                    f"says one was dropped: {span!r}")
            if note is not None and note not in span:
                raise AssertionError(
                    f"at {inner} inner cells the row dropped a hearth without "
                    f"saying {note!r}: {span!r}")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Overview")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="board hearth census width",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("the hearth census row budgets what it draws: PASS")
