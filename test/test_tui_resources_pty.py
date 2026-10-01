"""The existing MCP resource reading scenario, selectable by renderer owner."""

import os
import sys

from tui_keyboard_harness import ScenarioFamily, main
from tui_keyboard_resources import run_resources_regression

SOURCE_MODULES = (
    "test/tui_keyboard_harness.py",
    "test/tui_keyboard_resources.py",
    "bin/masc_tui_render_resources.ml",
    "bin/masc_tui_render_resources.mli",
    "bin/masc_tui_render_prim.ml",
    "bin/masc_tui_render_prim.mli",
)

if __name__ == "__main__":
    family = ScenarioFamily("resources", "MCP resource reading regression", (run_resources_regression,))
    main([os.path.abspath(sys.argv[1]), "resources"], (family,), family)
