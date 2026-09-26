"""Keyboard PTY rosters scenarios in the Dune parallel batch."""

import os
import sys

import test_tui_keyboard_input as keyboard

SOURCE_MODULES = (
    "bin/masc_tui_roster_pane.ml",
    "bin/masc_tui_keys.ml",
)

if __name__ == "__main__":
    keyboard.run_keyboard_regression(os.path.abspath(sys.argv[1]), group=3)
    print("tui keyboard rosters PTY regression: PASS")
