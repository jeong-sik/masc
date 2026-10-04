"""The existing MCP resource reading scenario, selectable by renderer owner."""

import os
import sys

from tui_keyboard_harness import ScenarioFamily, main
from tui_keyboard_resources import run_resources_regression



if __name__ == "__main__":
    family = ScenarioFamily("resources", "MCP resource reading regression", (run_resources_regression,))
    main([os.path.abspath(sys.argv[1]), "resources"], (family,), family)
