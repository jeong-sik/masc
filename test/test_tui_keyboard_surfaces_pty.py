"""Keyboard PTY surfaces scenarios in the Dune parallel batch."""

import os
import sys
import time

import tui_keyboard_walk as keyboard



if __name__ == "__main__":
    started = time.monotonic()
    keyboard.run_keyboard_regression(os.path.abspath(sys.argv[1]), group=1)
    finished = time.monotonic()
    print(f"tui keyboard surfaces PTY regression: PASS start={started:.6f} end={finished:.6f}")
