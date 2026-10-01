"""Keyboard PTY general scenarios in the Dune parallel batch."""

import tui_keyboard_walk as _keyboard_walk
import tui_keyboard_context as _keyboard_context

import os
import sys
import time

import tui_keyboard_walk as keyboard

SOURCE_MODULES = (
    "bin/masc_tui_palette.ml",
    "bin/masc_tui_palette.mli",
    "lib/tui_terminal_text.ml",
    "lib/tui_terminal_text.mli",
    "bin/masc_tui_render_chat.ml",
    "bin/masc_tui_message_layout.ml",
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
    "bin/masc_tui_next_request_band.ml",
)

if __name__ == "__main__":
    started = time.monotonic()
    executable = os.path.abspath(sys.argv[1])
    _keyboard_context.run_next_request_readability_regression(executable)
    _keyboard_walk.run_keyboard_regression(executable, group=0)
    finished = time.monotonic()
    print(f"tui keyboard general PTY regression: PASS start={started:.6f} end={finished:.6f}")
