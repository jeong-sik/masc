"""Keyboard PTY board terminal scenarios in the Dune parallel batch."""

import os
import sys
import time

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_walk as _keyboard_walk




def vote_hint_at_narrow_width(executable: str) -> None:
    fixtures = _keyboard_harness.board_selection_http_fixtures()

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.tab_until(process, fd, output, b"MASC Board")
        _keyboard_harness.wait_for_output(process, fd, output, b"Alpha", start=0, timeout=10)
        frame = _keyboard_harness.resize_and_wait(
            process, fd, output, rows=32, columns=80,
            needle=b"Alpha", controls=(_keyboard_harness.FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        visible = _keyboard_harness.screen_text(frame)
        if b"v / V:up / down" not in visible:
            raise AssertionError(f"80-column Board hid the vote directions: {visible!r}")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable, description="Board vote directions at 80 columns",
        interact=interact, http_fixtures=fixtures,
    )


if __name__ == "__main__":
    started = time.monotonic()
    executable = os.path.abspath(sys.argv[1])
    _keyboard_walk.run_keyboard_regression(executable, group=4)
    vote_hint_at_narrow_width(executable)
    finished = time.monotonic()
    print(f"tui keyboard board terminal PTY regression: PASS start={started:.6f} end={finished:.6f}")
