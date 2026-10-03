"""The Activity pane opens only when the surface keeps its floor."""
import os
import sys

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_keepers as _keyboard_keepers




if __name__ == "__main__":
    _keyboard_harness.run_terminal_scenario(
        os.path.abspath(sys.argv[1]),
        description="The Activity pane opens only with the surface floor left",
        interact=_keyboard_keepers.acting_pane_floor_interaction,
    )
    print("Activity pane floor: PASS")
