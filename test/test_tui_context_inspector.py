"""Run the turn-record Context Inspector fixture without the full keyboard walk."""
from __future__ import annotations

import sys

import test_tui_keyboard_input as _keyboard_entry
import tui_keyboard_harness as keyboard



if __name__ == "__main__":
    keyboard.main(
        [sys.argv[1], "--scenario", "Keeper provider-input Context Inspector"],
        _keyboard_entry.SCENARIO_FAMILIES,
        _keyboard_entry.KEYBOARD_FAMILY,
    )
