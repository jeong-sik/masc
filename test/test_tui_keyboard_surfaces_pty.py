"""Keyboard PTY surfaces scenarios in the Dune parallel batch."""

import os
import sys

import test_tui_keyboard_input as keyboard

SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
    "bin/masc_tui_types.ml",
)

if __name__ == "__main__":
    keyboard.run_keyboard_regression(os.path.abspath(sys.argv[1]), group=1)
    print("tui keyboard surfaces PTY regression: PASS")
