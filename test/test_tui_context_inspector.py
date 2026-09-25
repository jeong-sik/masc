"""Run the turn-record Context Inspector fixture without the full keyboard walk."""
from __future__ import annotations

import sys

import test_tui_keyboard_input as keyboard

# The HTTP fixture in context_inspector_fixtures() is a consumer of these
# contracts. run-edited-tests.sh selects this focused suite when one moves.
SOURCE_MODULES = (
    "lib/types/turn_record.ml",
    "lib/types/turn_record.mli",
    "lib/types/runtime_usage_scope.ml",
    "lib/types/runtime_usage_scope.mli",
)

if __name__ == "__main__":
    keyboard.main(
        [sys.argv[1], "--scenario", "Keeper provider-input Context Inspector"],
        keyboard.SCENARIO_FAMILIES,
        keyboard.KEYBOARD_FAMILY,
    )
