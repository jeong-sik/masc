"""Keyboard PTY board terminal scenarios in the Dune parallel batch."""

import os
import sys
import time

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_walk as _keyboard_walk

SOURCE_MODULES = (
    "bin/masc_tui_board_requests.ml",
    "bin/masc_tui_board_requests.mli",
    "bin/masc_tui_board_updates.ml",
    "bin/masc_tui_board_updates.mli",
    "bin/masc_tui_render_approvals.ml",
    "bin/masc_tui_render_approvals.mli",
    "bin/masc_tui.ml",
    "bin/masc_tui_render_board.ml",
    "bin/masc_tui_render_board.mli",
    "bin/masc_tui_input_reader.ml",
    "bin/masc_tui_input_reader.mli",
    "bin/masc_tui_markdown.ml",
    "bin/masc_tui_input_decoder.ml",
    "bin/masc_tui_keys.ml",
    "bin/masc_tui_render_schedule.ml",
    "test/tui_keyboard_approvals.py",
    "test/tui_keyboard_board.py",
    "test/tui_keyboard_chat.py",
    "test/tui_keyboard_clients.py",
    "test/tui_keyboard_context.py",
    "test/tui_keyboard_dashboard.py",
    "test/tui_keyboard_fusion.py",
    "test/tui_keyboard_harness.py",
    "test/tui_keyboard_keepers.py",
    "test/tui_keyboard_memory.py",
    "test/tui_keyboard_observer.py",
    "test/tui_keyboard_planning.py",
    "test/tui_keyboard_runtime.py",
    "test/tui_keyboard_schedule.py",
    "test/tui_keyboard_startup.py",
    "test/tui_keyboard_terminal.py",
    "test/tui_keyboard_tools.py",
    "test/tui_keyboard_walk.py",
    "test/tui_keyboard_workspace.py",
)


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
