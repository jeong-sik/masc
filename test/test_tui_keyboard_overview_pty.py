"""Keyboard PTY overview scenarios in the Dune parallel batch."""

import os
import sys
import time

import test_tui_keyboard_input as keyboard

SOURCE_MODULES = (
    "bin/masc_tui_overview_tasks.ml",
    "bin/masc_tui_render_schedule.ml",
)

if __name__ == "__main__":
    started = time.monotonic()
    keyboard.run_keyboard_regression(os.path.abspath(sys.argv[1]), group=2)
    finished = time.monotonic()
    print(f"tui keyboard overview PTY regression: PASS start={started:.6f} end={finished:.6f}")
