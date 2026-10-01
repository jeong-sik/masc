"""Focused PTY coverage for chat input moved out of the serial keyboard walk."""

import os
import sys
import time

import tui_keyboard_walk as keyboard

# The edited-test selector reads these exact source paths.
SOURCE_MODULES = (
    "bin/masc_tui_async_protocol.ml",
    "bin/masc_tui_async_protocol.mli",
    "bin/masc_tui_input_reader.ml",
    "bin/masc_tui_input_reader.mli",
    "bin/masc_tui.ml",
    "bin/masc_tui_composer.ml",
    "bin/masc_tui_input_decoder.ml",
    "bin/masc_tui_paste.ml",
    "bin/masc_tui_paste_spill.ml",
    "bin/masc_tui_utf8_input.ml",
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
    keyboard.run_chat_input_regression(os.path.abspath(sys.argv[1]))
    finished = time.monotonic()
    print(f"tui chat input PTY regression: PASS start={started:.6f} end={finished:.6f}")
