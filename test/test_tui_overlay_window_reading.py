"""The overlays say which of their lines these are.

The sheet is longer than any terminal -- at 150x78 the later sections are
still off screen -- and it drew no reading of where the viewport stood, so a
reader pressing [j] could not tell a page from a hundred. Measured on the
live server: 670 lines at 24x80, 568 at 46x120.

It also pins the pair the keypress and the drawing share. [G] bounds the
scroll through Masc_tui_render.help_viewport; a drawing that used a
different height would leave the last line off screen after [G].

The Agenda panel draws the same reading through the same helper. Its
overflow was measured on the live server -- sixteen of thirty-two lines at
24x100, and neither of the two sections under them -- and is not reproduced
here: the panel is fed by the scheduled-automation endpoint, whose rows
carry fifteen required fields each, and this scenario's workspace holds
seven agenda lines. What it pins is the other half: a panel that fits draws
no reading at all.
"""
import os
import re
import sys

import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs a
# suite when a pull request changes a path the suite names.
SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
)

SHEET = b"MASC Cheat Sheet"
WINDOW = re.compile(rb"\[lines (\d+)-(\d+)/(\d+)\]")
# The deletion record overlay's own title. [D] opens it and reads; the key
# that deletes a keeper is [x].
DELETIONS = "\ud0a4\ud37c \uc0ad\uc81c \uae30\ub85d".encode()


def window_of(drawn: bytes, where: str) -> tuple[int, int, int]:
    screen = b"\n".join(h.screen_rows(drawn).values())
    found = WINDOW.search(screen)
    if not found:
        raise AssertionError(f"{where}: the sheet drew no window: {screen!r}")
    return tuple(int(group) for group in found.groups())


def run(executable: str) -> None:
    def interact(process, fd, _slave, output, _base_path):
        h.wait_for_output(process, fd, output, b"MASC Overview", start=0,
                          timeout=15)
        drawn = h.resize_and_wait(process, fd, output, rows=24, columns=80,
                                  needle=b"MASC Overview",
                                  controls=(h.FULL_REDRAW,))
        drawn = h.send_and_wait(process, fd, output, b"?", SHEET)
        first, last, total = window_of(drawn, "at the top of the sheet")
        if first != 1:
            raise AssertionError(f"the sheet opened at line {first}, not 1")
        if total <= last:
            raise AssertionError(
                f"the sheet says it holds {total} lines and shows up to "
                f"{last}, so it is not a window")
        height = last - first + 1

        # [G] bounds the scroll through the same viewport the frame draws
        # with, so the last line of the sheet is the last line on screen.
        # Waited on the reading rather than on the title: [G] redraws the
        # rows it moved, and the title above them is not one of them.
        drawn = h.send_and_wait(process, fd, output, b"G", b"[lines ")
        g_first, g_last, g_total = window_of(drawn, "after G")
        if g_total != total:
            raise AssertionError(
                f"the sheet held {total} lines and now holds {g_total}")
        if g_last != total:
            raise AssertionError(
                f"G left the sheet at {g_first}-{g_last} of {total}, so its "
                "last line is off screen")
        if g_last - g_first + 1 != height:
            raise AssertionError(
                f"the viewport was {height} rows at the top and "
                f"{g_last - g_first + 1} after G")

        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Overview")

        # The Agenda panel holds seven lines here and its viewport is taller
        # than that at every size this scenario uses, so it has nothing to
        # say and says nothing.
        drawn = h.send_and_wait(process, fd, output, b";", b"MASC Agenda")
        screen = b"\n".join(h.screen_rows(drawn).values())
        found = WINDOW.search(screen)
        if found:
            raise AssertionError(
                "the Agenda fits its viewport, so the reading says nothing "
                f"the rows do not: {found.group(0)!r}")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Overview")

        # The deletion record overlay draws the same reading. Here the record
        # is one row -- this workspace has no deletion inventory to read --
        # so it fits and says nothing. On the live server the record is one
        # JSON document that ran past every height measured.
        h.palette_go(process, fd, output, b"go keepers", b"MASC Keepers")
        drawn = h.send_and_wait(process, fd, output, b"D", DELETIONS)
        screen = b"\n".join(h.screen_rows(drawn).values())
        found = WINDOW.search(screen)
        if found:
            raise AssertionError(
                "the deletion record fits its viewport, so the reading says "
                f"nothing the rows do not: {found.group(0)!r}")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
                            description="overlay window reading",
                            interact=interact,
                            http_fixtures=h.keeper_runtime_http_fixtures())


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("the overlays say which lines these are: PASS")
