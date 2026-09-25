"""The Voice pane's footer is the last row of its body.

The pane draws its frame by hand and drew only the lines it had, so the box
bottom and the footer sat under the last line wherever that landed. Measured
on the live server: the footer stood on row 24 of a forty-four row terminal
with eighteen blank rows under it, and on row 24 of a thirty row one. At
twenty-four rows the reading happened to fill the pane and the footer landed
where it belongs, which is why the pane looks right until the terminal grows.

The cheat sheet and the answering overlay were moved off the same hand-drawn
frame for the same reason.
"""
import os
import sys

import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs a
# suite when a pull request changes a path the suite names.
SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
)

VOICE = b"MASC Voice"
FOOTER = b"Esc:overview"


def rows_under_the_footer(drawn: bytes, where: str) -> list[bytes]:
    rows = h.screen_rows(drawn)
    index = h.screen_row_of(rows, FOOTER)
    if index < 0:
        raise AssertionError(f"{where}: the pane drew no footer: {rows!r}")
    return [rows[key].rstrip() for key in sorted(rows) if key > index]


def open_voice(process, fd, output) -> bytes:
    """Walked with [p] rather than named: the pane order is the Config
    strip's, and a walk that does not reach Voice says so."""
    drawn = h.palette_go(process, fd, output, b"go config", b"MASC Config")
    for _ in range(10):
        drawn = h.send_and_wait(process, fd, output, b"p", b"MASC ")
        if VOICE in b"\n".join(h.screen_rows(drawn).values()):
            return drawn
    raise AssertionError("ten presses of [p] never reached the Voice pane")


def run(executable: str) -> None:
    def interact(process, fd, _slave, output, _base_path):
        h.wait_for_output(process, fd, output, b"MASC Overview", start=0,
                          timeout=15)
        # Opened at a height neither measurement uses: resizing to the size
        # the terminal already has sends no SIGWINCH and redraws nothing.
        h.resize_and_wait(process, fd, output, rows=32, columns=110,
                          needle=b"MASC Overview", controls=(h.FULL_REDRAW,))
        open_voice(process, fd, output)

        tails = {}
        for rows in (40, 24):
            drawn = h.resize_and_wait(process, fd, output, rows=rows,
                                      columns=110, needle=FOOTER,
                                      controls=(h.FULL_REDRAW,))
            under = rows_under_the_footer(drawn, f"at {rows} rows")
            blank = [row for row in under if not row]
            if blank:
                raise AssertionError(
                    f"at {rows} rows the pane left {len(blank)} blank rows "
                    f"under its footer: {under!r}")
            tails[rows] = len(under)

        if tails[40] != tails[24]:
            raise AssertionError(
                "the footer sits a different distance from the bottom at the "
                f"two heights: {tails}")

        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Overview")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
                            description="voice pane fills its height",
                            interact=interact,
                            http_fixtures=h.keeper_runtime_http_fixtures())


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("the Voice pane's footer is its last body row: PASS")
