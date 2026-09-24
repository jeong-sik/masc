"""A roster taller than its rows says which keepers it is drawing.

Measured against the live server at 24 terminal rows: the roster drew eleven
of nineteen keepers, and no row on the screen said the other eight were
there. Every other scrolled list on the screen draws the window it stands in
through Masc_tui_scroll.window_text.
"""
import json
import os
import re
import sys
from pathlib import Path

import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs a
# suite when a pull request changes a path the suite names.
SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
)

TITLE = b"MASC Keepers"
WINDOW = re.compile(rb"\[keepers (\d+)-(\d+)/(\d+)\]")
# The first hint of the footer, which this surface draws under the roster.
FOOTER = b"j/k:move"

# Named to sort ahead of the two keepers every scenario's workspace is seeded
# with, so a window that starts at the first row holds these and only these.
NAMES = tuple("aa-roster-%02d" % n for n in range(1, 13))
LAST = NAMES[-1].encode()


def prepare(base_path: str) -> None:
    """Written here rather than added to [seed_workspace]: that roster is
    walked row by row by other scenarios."""
    keepers = Path(base_path) / ".masc" / "keepers"
    keepers.mkdir(parents=True, exist_ok=True)
    for name in NAMES:
        (keepers / f"{name}.json").write_text(
            json.dumps(h.keeper_metadata(name)), encoding="utf-8")


def screen_of(drawn: bytes) -> bytes:
    return b"\n".join(h.screen_rows(drawn).values())


def drawn_names(screen: bytes) -> list[str]:
    return [name for name in NAMES if name.encode() in screen]


def run(executable: str) -> None:
    def interact(process, fd, _slave, output, _base_path):
        h.wait_for_output(process, fd, output, b"MASC Overview", start=0,
                          timeout=15)
        h.palette_go(process, fd, output, b"go keepers", TITLE)
        # The roster is read off .masc/keepers on a refresh tick, so the
        # first frame can still say "(not loaded)". Every resize below is a
        # reading of what the roster holds, so wait for it to hold something:
        # on a Linux runner the scenario read an unloaded roster and asked
        # why its rows were missing.
        h.wait_for_output(process, fd, output, LAST, start=0, timeout=20)

        # Tall: every keeper has a row, so there is nothing for the line to
        # say that the rows do not.
        # Waited on the footer rather than on a roster row: the roster is
        # drawn above it, so a frame that carries the footer carries every
        # row this scenario reads.
        drawn = h.resize_and_wait(process, fd, output, rows=44, columns=120,
                                  needle=FOOTER, controls=(h.FULL_REDRAW,))
        screen = screen_of(drawn)
        if LAST not in screen:
            raise AssertionError(
                f"at 44 rows the roster did not draw {LAST!r}: {screen!r}")
        found = WINDOW.search(screen)
        if found:
            raise AssertionError(
                "at 44 rows the whole roster fits, so the window line says "
                f"nothing the rows do not: {found.group(0)!r}")

        # Short: the roster runs past its rows.
        drawn = h.resize_and_wait(process, fd, output, rows=20, columns=120,
                                  needle=FOOTER, controls=(h.FULL_REDRAW,))
        screen = screen_of(drawn)
        if LAST in screen:
            raise AssertionError(
                "at 20 rows the roster still fits, so this scenario proves "
                "nothing")
        found = WINDOW.search(screen)
        if not found:
            raise AssertionError(
                "at 20 rows the roster dropped keepers and said nothing: "
                f"{screen!r}")
        first, last, total = (int(group) for group in found.groups())
        here = drawn_names(screen)
        if first != 1 or last - first + 1 != len(here):
            raise AssertionError(
                f"the window says {first}-{last} and {len(here)} of these "
                f"keepers are drawn: {here}")
        if total <= last:
            raise AssertionError(
                f"the window says it holds {total} and shows up to {last}, "
                "so it is not a window")

        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Overview")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
                            description="keeper roster window line",
                            interact=interact,
                            # The roster comes off disk on a tick; the
                            # default minute is longer than this scenario.
                            refresh=0.5,
                            http_fixtures=h.keeper_runtime_http_fixtures(),
                            prepare_workspace=prepare)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("the keeper roster says which keepers it draws: PASS")
