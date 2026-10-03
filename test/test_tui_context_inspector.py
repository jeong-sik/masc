"""Run the turn-record Context Inspector fixture without the full keyboard walk."""
from __future__ import annotations

import sys

import test_tui_keyboard_input as keyboard



if __name__ == "__main__":
    keyboard.main(
        [sys.argv[1], "--scenario", "Keeper provider-input Context Inspector"],
        keyboard.SCENARIO_FAMILIES,
        keyboard.KEYBOARD_FAMILY,
    )
