"""The Activity pane opens only when the surface keeps its floor."""
import os
import sys
import test_tui_keyboard_input as h




if __name__ == "__main__":
    h.run_terminal_scenario(
        os.path.abspath(sys.argv[1]),
        description="The Activity pane opens only with the surface floor left",
        interact=h.acting_pane_floor_interaction,
    )
    print("Activity pane floor: PASS")
