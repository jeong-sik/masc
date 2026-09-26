"""Focused PTY coverage for chat input moved out of the serial keyboard walk."""

import os
import sys

import test_tui_keyboard_input as keyboard

# The edited-test selector reads these exact source paths.
SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_composer.ml",
    "bin/masc_tui_input_decoder.ml",
    "bin/masc_tui_paste.ml",
    "bin/masc_tui_paste_spill.ml",
    "bin/masc_tui_utf8_input.ml",
)


if __name__ == "__main__":
    keyboard.run_chat_input_regression(os.path.abspath(sys.argv[1]))
    print("tui chat input PTY regression: PASS")
