"""Keyboard PTY board terminal scenarios in the Dune parallel batch."""

import os
import sys

import test_tui_keyboard_input as keyboard

SOURCE_MODULES = (
    "bin/masc_tui_markdown.ml",
    "bin/masc_tui_input_decoder.ml",
)

if __name__ == "__main__":
    keyboard.run_keyboard_regression(os.path.abspath(sys.argv[1]), group=4)
    print("tui keyboard board terminal PTY regression: PASS")
