"""Keyboard PTY surfaces scenarios in the Dune parallel batch."""

import os
import sys
import time

import test_tui_keyboard_input as keyboard

SOURCE_MODULES = (
    "bin/masc_tui_render_fusion.ml",
    "bin/masc_tui_render_fusion.mli",
    "bin/masc_tui_fusion_model.ml",
    "bin/masc_tui_fusion_model.mli",
    "bin/masc_tui_surface_search.ml",
    "bin/masc_tui_surface_search.mli",
    "bin/masc_tui_fusion_updates.ml",
    "bin/masc_tui_fusion_updates.mli",
    "bin/masc_tui_palette.ml",
    "bin/masc_tui_palette.mli",
    "lib/tui_terminal_text.ml",
    "lib/tui_terminal_text.mli",
    "bin/masc_tui_render_prim.ml",
    "bin/masc_tui_render_prim.mli",
    "bin/masc_tui_render_code.ml",
    "bin/masc_tui_render_code.mli",
    "bin/masc_tui_approvals_model.ml",
    "bin/masc_tui_approvals_model.mli",
    "bin/masc_tui_surface_navigation.ml",
    "bin/masc_tui_surface_navigation.mli",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_types.ml",
    "bin/masc_tui_code_updates.ml",
    "bin/masc_tui_code_updates.mli",
)

if __name__ == "__main__":
    started = time.monotonic()
    keyboard.run_keyboard_regression(os.path.abspath(sys.argv[1]), group=1)
    finished = time.monotonic()
    print(f"tui keyboard surfaces PTY regression: PASS start={started:.6f} end={finished:.6f}")
