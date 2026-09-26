"""Keyboard PTY overview scenarios in the Dune parallel batch."""

import os
import sys

import test_tui_keyboard_input as keyboard

SOURCE_MODULES = (
    "bin/masc_tui_overview_tasks.ml",
    "bin/masc_tui_render_schedule.ml",
)

if __name__ == "__main__":
    keyboard.run_keyboard_regression(os.path.abspath(sys.argv[1]), group=2)
    print("tui keyboard overview PTY regression: PASS")
