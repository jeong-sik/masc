"""Focused PTY coverage for chat input moved out of the serial keyboard walk."""

import os
import sys
import time

import tui_keyboard_walk as keyboard




if __name__ == "__main__":
    started = time.monotonic()
    keyboard.run_chat_input_regression(os.path.abspath(sys.argv[1]))
    finished = time.monotonic()
    print(f"tui chat input PTY regression: PASS start={started:.6f} end={finished:.6f}")
