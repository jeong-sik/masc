"""The keeper-row scan reads the screen on display, not every screen drawn.

`output` in the PTY harness is append-only: it holds every frame the run has
produced. `select_keeper_row` used to scan it from byte zero, so a keeper name
in an Overview activity line -- or a selected row from an earlier visit to
Keepers -- answered for the screen that is on display now, and the helper
returned a cursor that was not on the row the scenario asked for.

This is the offset that fixes it, checked without a terminal: the cases below
are byte streams, not screens.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import test_tui_keyboard_input as h  # noqa: E402


def frame(rows: bytes) -> bytes:
    """One frame: the header the scenarios wait for, then rows."""
    return b"\x1b[2J\x1b[1;1H  " + h.KEEPERS_HEADER + b"  \x1b[3;1H" + rows


def selected(name: bytes) -> bytes:
    """A row drawn as selected, in the shape keeper_row_selected matches."""
    return b"\x1b[7m  " + name + b"                \x1b[0m"


def unselected(name: bytes) -> bytes:
    return b"  \x1b[2m" + name + b"\x1b[0m  "


def main() -> None:
    needle = h.keeper_row_selected(b"alpha")

    # A selected alpha row from an earlier Keepers visit, then a fresh screen
    # whose roster has not landed yet. Scanning from zero finds the stale band
    # and calls the cursor placed; from the current screen it finds nothing.
    stale = bytearray(frame(selected(b"alpha")) + frame(b"  (0)"))
    entry = h.current_screen_start(stale, h.KEEPERS_HEADER)
    assert entry > 0, "the second header has to be where the current screen starts"
    assert h.find_needle(stale, needle, 0) >= 0, (
        "fixture is wrong: the stale band must be findable from zero, "
        "or this case proves nothing"
    )
    assert h.find_needle(stale, needle, entry) < 0, (
        "a selected row from a screen that is gone must not answer for the "
        "one on display"
    )

    # The same shape once the roster does land: found, from the current screen.
    landed = bytearray(
        frame(selected(b"alpha")) + frame(b"  (0)") + selected(b"alpha")
    )
    assert h.find_needle(landed, needle, h.current_screen_start(landed, h.KEEPERS_HEADER)) >= 0

    # An Overview line that merely names the keeper is not a selected row.
    named_only = bytearray(frame(unselected(b"alpha")))
    assert h.find_needle(named_only, needle, h.current_screen_start(named_only, h.KEEPERS_HEADER)) < 0

    # Before any header there is nothing else to start from.
    assert h.current_screen_start(bytearray(b"no header here"), h.KEEPERS_HEADER) == 0

    print("keeper row scan reads the current screen: PASS")


if __name__ == "__main__":
    main()
