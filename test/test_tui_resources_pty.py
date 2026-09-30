"""The existing MCP resource reading scenario, selectable by renderer owner."""

import os
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_resources_updates.ml",
    "bin/masc_tui_resources_updates.mli",
    "bin/masc_tui_render_resources.ml",
    "bin/masc_tui_render_resources.mli",
    "bin/masc_tui_render_prim.ml",
    "bin/masc_tui_render_prim.mli",
)

if __name__ == "__main__":
    h.main([os.path.abspath(sys.argv[1]), "resources"], h.SCENARIO_FAMILIES, h.KEYBOARD_FAMILY)
