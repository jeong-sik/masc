"""Standalone driver for the 'Keeper Memory journal timeline' PTY scenario.

run_keyboard_regression() has no argv selector (unlike chat-clarity/runtime/
etc.) and #30140 documents the suite as a fossil layer where an earlier
scenario's failure can mask this one. This driver imports the scenario's
own setup verbatim (see test_tui_keyboard_input.py's memory-journal call
site) and runs only it, in isolation, to get an honest current-main
verdict for #30455 without paying for or risking the other 77 scenarios.
"""
import sys

sys.path.insert(0, "test")
import test_tui_keyboard_input as t  # noqa: E402

executable = sys.argv[1]
memory_journal_sequence = t.SequencedHttpResponse([t.memory_journal_fixture()])
t.run_terminal_scenario(
    executable,
    description="Keeper Memory journal timeline",
    interact=t.memory_journal_timeline_interaction(memory_journal_sequence),
    http_fixtures={
        "/api/v1/keepers/alpha/chat/history": t.memory_journal_chat_fixture(),
        "/api/v1/keepers/alpha/memory-journal?limit=20": memory_journal_sequence,
    },
    refresh=0.5,
)
print("memory-journal isolated scenario: PASS")
