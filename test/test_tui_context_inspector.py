"""Run the turn-record Context Inspector fixture without the full keyboard walk."""
from __future__ import annotations

import sys

import test_tui_keyboard_input as _keyboard_entry
import tui_keyboard_harness as keyboard

# The HTTP fixture in context_inspector_fixtures() is a consumer of these
# contracts. run-edited-tests.sh selects this focused suite when one moves.
SOURCE_MODULES = (
    "lib/types/turn_record.ml",
    "lib/types/turn_record.mli",
    "lib/types/runtime_usage_scope.ml",
    "lib/types/runtime_usage_scope.mli",
    "test/test_tui_keyboard_input.py",
    "test/tui_keyboard_approvals.py",
    "test/tui_keyboard_board.py",
    "test/tui_keyboard_browser.py",
    "test/tui_keyboard_chat.py",
    "test/tui_keyboard_clients.py",
    "test/tui_keyboard_context.py",
    "test/tui_keyboard_dashboard.py",
    "test/tui_keyboard_fusion.py",
    "test/tui_keyboard_harness.py",
    "test/tui_keyboard_keepers.py",
    "test/tui_keyboard_machines.py",
    "test/tui_keyboard_memory.py",
    "test/tui_keyboard_observer.py",
    "test/tui_keyboard_planning.py",
    "test/tui_keyboard_repositories.py",
    "test/tui_keyboard_resources.py",
    "test/tui_keyboard_runtime.py",
    "test/tui_keyboard_schedule.py",
    "test/tui_keyboard_startup.py",
    "test/tui_keyboard_terminal.py",
    "test/tui_keyboard_tools.py",
    "test/tui_keyboard_voice.py",
    "test/tui_keyboard_walk.py",
    "test/tui_keyboard_workspace.py",
)

if __name__ == "__main__":
    keyboard.main(
        [sys.argv[1], "--scenario", "Keeper provider-input Context Inspector"],
        _keyboard_entry.SCENARIO_FAMILIES,
        _keyboard_entry.KEYBOARD_FAMILY,
    )
