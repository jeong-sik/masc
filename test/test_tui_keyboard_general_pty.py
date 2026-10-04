"""Keyboard PTY general scenarios in the Dune parallel batch."""

import tui_keyboard_walk as _keyboard_walk
import tui_keyboard_context as _keyboard_context

import os
import sys
import time

import tui_keyboard_walk as keyboard



if __name__ == "__main__":
    started = time.monotonic()
    executable = os.path.abspath(sys.argv[1])
    _keyboard_context.run_next_request_readability_regression(executable)
    _keyboard_walk.run_keyboard_regression(executable, group=0)
    finished = time.monotonic()
    print(f"tui keyboard general PTY regression: PASS start={started:.6f} end={finished:.6f}")
