"""Keyboard PTY board terminal scenarios in the Dune parallel batch."""

import os
import sys
import time

import test_tui_keyboard_input as keyboard

SOURCE_MODULES = (
    "bin/masc_tui_board_updates.ml",
    "bin/masc_tui_board_updates.mli",
    "bin/masc_tui.ml",
    "bin/masc_tui_render_board.ml",
    "bin/masc_tui_render_board.mli",
    "bin/masc_tui_render_approvals.ml",
    "bin/masc_tui_render_approvals.mli",
    "bin/masc_tui_input_reader.ml",
    "bin/masc_tui_input_reader.mli",
    "bin/masc_tui_markdown.ml",
    "bin/masc_tui_input_decoder.ml",
    "bin/masc_tui_keys.ml",
    "bin/masc_tui_render_schedule.ml",
)


def vote_hint_at_narrow_width(executable: str) -> None:
    fixtures = keyboard.board_selection_http_fixtures()

    def interact(process, fd, _slave, output, _base):
        keyboard.tab_until(process, fd, output, b"MASC Board")
        keyboard.wait_for_output(process, fd, output, b"Alpha", start=0, timeout=10)
        frame = keyboard.resize_and_wait(
            process, fd, output, rows=32, columns=80,
            needle=b"Alpha", controls=(keyboard.FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        visible = keyboard.screen_text(frame)
        if b"v / V:up / down" not in visible:
            raise AssertionError(f"80-column Board hid the vote directions: {visible!r}")
        os.write(fd, b"q")

    keyboard.run_terminal_scenario(
        executable, description="Board vote directions at 80 columns",
        interact=interact, http_fixtures=fixtures,
    )


if __name__ == "__main__":
    started = time.monotonic()
    executable = os.path.abspath(sys.argv[1])
    keyboard.run_keyboard_regression(executable, group=4)
    vote_hint_at_narrow_width(executable)
    finished = time.monotonic()
    print(f"tui keyboard board terminal PTY regression: PASS start={started:.6f} end={finished:.6f}")
