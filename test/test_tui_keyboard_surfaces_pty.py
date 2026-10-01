"""Keyboard PTY surfaces scenarios in the Dune parallel batch."""

import os
import sys
import time

import tui_keyboard_walk as keyboard

SOURCE_MODULES = (
    "bin/masc_tui_code_results.ml",
    "bin/masc_tui_code_results.mli",
    "bin/masc_tui_palette.ml",
    "bin/masc_tui_palette.mli",
    "lib/tui_terminal_text.ml",
    "lib/tui_terminal_text.mli",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_types.ml",
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

if __name__ == "__main__":
    started = time.monotonic()
    keyboard.run_keyboard_regression(os.path.abspath(sys.argv[1]), group=1)
    finished = time.monotonic()
    print(f"tui keyboard surfaces PTY regression: PASS start={started:.6f} end={finished:.6f}")
