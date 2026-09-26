"""Keyboard PTY general scenarios in the Dune parallel batch."""

import os
import sys

import test_tui_keyboard_input as keyboard

SOURCE_MODULES = (
    "bin/masc_tui_render_chat.ml",
    "bin/masc_tui_message_layout.ml",
)

if __name__ == "__main__":
    keyboard.run_keyboard_regression(os.path.abspath(sys.argv[1]), group=0)
    print("tui keyboard general PTY regression: PASS")
