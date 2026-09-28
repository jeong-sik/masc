"""Where four surfaces put their title, their first row, their footer and
their blank rows, at the widths the region work is judged at.

The workbench RFC's region steps (section 5.9, G0 to G5) move rows: G0
makes every reader of the frame's row count read one value from
Masc_tui_frame, and later steps drop the title underline and merge rows.
This suite pins where the rows sit today, so each step changes these
numbers on purpose and its diff shows what moved. It also prints the raw
ANSI of every measured screen to the test log, zlib-compressed and base64
between markers, so a reviewer can rebuild the screen from a CI run without
a local binary.

The surfaces are the ones the G0 readers draw: the Keepers list (the shared
body height), a keeper's detail pane, the keeper chat (its history's first
row) and the Board list, with the harness's keepers alpha and beta and four
Board posts. The Lane run detail and Memory are not measured here.
"""
import base64
import os
import sys
import zlib

import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs
# a suite when a pull request changes a path the suite names. The frame's row
# count lives in masc_tui_frame; render_prim and render_chat read it.
# masc_tui_render.ml and masc_tui_types.ml read it too but are edited by most
# TUI pull requests, and a change to the count itself goes through the frame.
#
# Kept out of the default keyboard walk, which already runs near the CI limit
# (the PTY scenario guidance, #36343).
SOURCE_MODULES = (
    "bin/masc_tui_frame.ml",
    "bin/masc_tui_frame.mli",
    "bin/masc_tui_render_prim.ml",
    "bin/masc_tui_render_chat.ml",
)

TERMINAL_ROWS = 30

# 80 and 100 are the common terminals; 131 and 132 sit on either side of the
# width where the Activity pane used to open; 140 is the widest a surface is
# drawn at without the pane since it opens at 158.
WIDTHS = (80, 100, 131, 132, 140)

ALPHA_CHAT = b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat"
INFO_TAB = b"\xe2\x96\xb8Info"
# Every surface's key hints end with the help key, "…?"; the row that
# carries it is the surface's footer. On most surfaces the composer's row
# sits below it.
HELP_HINT = b"\xe2\x80\xa6?"

# (surface, width) -> (title row, first row drawn under it, footer row,
# blank rows between the title and the footer). Rows are the terminal's,
# counted from 1: the tab strip is row 1, the frame's top row 2, the title 3
# and its divider 4. The key hints sit on row 29 with the composer on row 30
# below them; the chat draws its own input and puts its hints on row 30. None
# of the four moves with the width today; the blank rows are what each
# surface's fixture leaves unfilled. Measured by Test run 36414157831 on
# 214fd9c212 (docs/evidence/tui-region-baseline-2026-09-28/README.md).
EXPECTED: dict[tuple[str, int], tuple[int, int, int, int]] = {
    (surface, width): rows
    for surface, rows in (
        ("keepers", (3, 4, 29, 16)),
        ("keeper-detail", (3, 4, 29, 7)),
        ("keeper-chat", (3, 4, 30, 18)),
        ("board", (3, 4, 29, 15)),
    )
    for width in WIDTHS
}


def measure(output: bytearray, title: bytes) -> tuple[int, int, int, int]:
    rows = h.screen_rows(bytes(output))
    title_row = h.screen_row_of(rows, title)
    if title_row < 0:
        raise AssertionError(f"{title!r} is not on screen: {rows!r}")
    drawn = [
        row
        for row in range(1, TERMINAL_ROWS + 1)
        if rows.get(row, b"").strip()
    ]
    hinted = [row for row in drawn if HELP_HINT in rows[row]]
    if not hinted:
        raise AssertionError(f"no row carries the key hints: {rows!r}")
    footer_row = max(hinted)
    below = [row for row in drawn if row > title_row]
    first_below = min(below) if below else -1
    blank = sum(
        1
        for row in range(title_row + 1, footer_row)
        if not rows.get(row, b"").strip()
    )
    return (title_row, first_below, footer_row, blank)


def print_frame(surface: str, width: int, output: bytearray) -> None:
    """The bytes the screen was built from, since the last full redraw.

    Compressed before it is encoded: dune cuts an action's output past a
    size, and uncompressed the twenty screens ran past it. A redraw is
    mostly padding, so it compresses to a small fraction."""
    drawn = bytes(output)
    cleared = drawn.rfind(h.FULL_REDRAW)
    if cleared >= 0:
        drawn = drawn[cleared:]
    encoded = base64.b64encode(zlib.compress(drawn, 9)).decode("ascii")
    print(f"=== region-baseline {surface} {width}x{TERMINAL_ROWS} begin ===")
    for start in range(0, len(encoded), 4096):
        print(encoded[start : start + 4096])
    print(f"=== region-baseline {surface} {width}x{TERMINAL_ROWS} end ===")


def region_baseline_interaction(process, fd, _slave, output, _base):
    measured: dict[tuple[str, int], tuple[int, int, int, int]] = {}

    def sweep(surface: str, title: bytes, needle=None) -> None:
        for width in WIDTHS:
            h.resize_and_wait(
                process,
                fd,
                output,
                rows=TERMINAL_ROWS,
                columns=width,
                needle=title if needle is None else needle,
                controls=(h.FULL_REDRAW,),
            )
            h.drain_until_quiet(process, fd, output, cap=3.0)
            measured[(surface, width)] = measure(output, title)
            print_frame(surface, width, output)

    h.tab_until(process, fd, output, b"MASC Keepers")
    sweep("keepers", b"MASC Keepers")

    h.select_keeper_row(process, fd, output, b"alpha")
    h.send_and_wait(process, fd, output, b"\r", INFO_TAB)
    sweep("keeper-detail", INFO_TAB)

    h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
    h.select_keeper_row(process, fd, output, b"alpha")
    h.send_and_wait(process, fd, output, b"c", ALPHA_CHAT)
    sweep("keeper-chat", ALPHA_CHAT)

    h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
    # The emphasis on the name closes between it and the count, so the wait
    # matches across it; the measure reads the screen's plain text.
    board_title = h.screen_header(b"MASC Board", b" (4)")
    h.palette_go(process, fd, output, b"go board", board_title)
    sweep("board", b"MASC Board (4)", needle=board_title)

    print("measured = {")
    for key, value in measured.items():
        print(f"    {key!r}: {value!r},")
    print("}")
    wrong = {
        key: (EXPECTED.get(key), value)
        for key, value in measured.items()
        if EXPECTED.get(key) != value
    }
    if wrong:
        raise AssertionError(
            "rows moved (expected, measured): "
            + ", ".join(f"{key}: {pair}" for key, pair in wrong.items())
        )
    h.send_and_wait(process, fd, output, b"q", b"q: press again to quit")


if __name__ == "__main__":
    h.run_terminal_scenario(
        os.path.abspath(sys.argv[1]),
        description="Region baseline: title, first row, footer and blank rows",
        interact=region_baseline_interaction,
        # Keepers alpha and beta and four Board posts, so the lists are
        # drawn with rows rather than with a load failure.
        http_fixtures=h.board_reference_http_fixtures(),
    )
    print("region baseline: PASS")
