"""The Activity pane opens only when the surface keeps its floor."""
import os
import sys

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_keepers as _keyboard_keepers

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs
# a suite when a pull request changes a path the suite names. When the pane
# opens is masc_tui_acting_pane.ml's; the floor it keeps is the frame's cells
# (masc_tui_frame.ml) plus the Keepers list's flag width
# (masc_tui_render_schedule.ml).
#
# Kept out of the default keyboard walk, which already runs near the CI limit
# (the PTY scenario guidance, #36343).
SOURCE_MODULES = (
    "bin/masc_tui_acting_pane.ml",
    "bin/masc_tui_frame.ml",
    "bin/masc_tui_render_schedule.ml",
    "test/tui_keyboard_harness.py",
    "test/tui_keyboard_keepers.py",
    "test/tui_keyboard_runtime.py",
)


if __name__ == "__main__":
    _keyboard_harness.run_terminal_scenario(
        os.path.abspath(sys.argv[1]),
        description="The Activity pane opens only with the surface floor left",
        interact=_keyboard_keepers.acting_pane_floor_interaction,
    )
    print("Activity pane floor: PASS")
