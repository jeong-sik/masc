"""Keyboard PTY general scenarios in the Dune parallel batch."""

import os
import sys
import time

import test_tui_keyboard_input as keyboard

SOURCE_MODULES = (
    "bin/masc_tui_identity_requests.ml",
    "bin/masc_tui_identity_requests.mli",
    "bin/masc_tui_identity_updates.ml",
    "bin/masc_tui_identity_updates.mli",
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
    "bin/masc_tui_render_chat.ml",
    "bin/masc_tui_message_layout.ml",
    "bin/masc_tui_code_updates.ml",
    "bin/masc_tui_code_updates.mli",
    "bin/masc_tui_code_requests.ml",
    "bin/masc_tui_code_requests.mli",
    "bin/masc_tui_next_request_band.ml",
)

if __name__ == "__main__":
    started = time.monotonic()
    executable = os.path.abspath(sys.argv[1])
    keyboard.run_next_request_readability_regression(executable)
    keyboard.run_keyboard_regression(executable, group=0)
    finished = time.monotonic()
    print(f"tui keyboard general PTY regression: PASS start={started:.6f} end={finished:.6f}")
