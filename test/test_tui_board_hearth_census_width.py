"""The Board's hearth census row budgets what it draws."""
import os
import sys
import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs a
# suite when a pull request changes a path the suite names.
SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
)

# No trailing space: the row draws the word dimmed, so a reset sits between
# "hearths" and the space after it and a needle carrying that space matches
# nothing in the raw output.
CENSUS_ROW = b"hearths"
TOTAL = b"198 posts"
DROPPED = b"+"
CUT = b"\xe2\x80\xa6"

# Eight hearths whose names and counts, laid out with the separator the row
# draws, run past any width this scenario uses. The row has to drop the ones
# that do not fit and still end on the total.
HEARTHS = [
    ("verification", 91),
    ("research", 58),
    ("code-review", 19),
    ("ops", 17),
    ("won-chik", 8),
    ("rondo", 3),
    ("general", 1),
    ("glossary-maniac", 1),
]


def census_row(rows: dict[int, bytes], columns: int) -> bytes:
    index = h.screen_row_of(rows, CENSUS_ROW)
    if index < 0:
        raise AssertionError(f"at {columns} columns the board drew no census row")
    return rows[index].rstrip()


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
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Overview")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="board hearth census width",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("the hearth census row budgets what it draws: PASS")
