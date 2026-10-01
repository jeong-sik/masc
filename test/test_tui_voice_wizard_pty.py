"""Existing voice wizard scenarios, selected by the session owner."""

import os
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_voice_wizard_session.ml",
    "bin/masc_tui_voice_wizard_session.mli",
)

if __name__ == "__main__":
    h.main([os.path.abspath(sys.argv[1]), "voice-wizard"], h.SCENARIO_FAMILIES, h.KEYBOARD_FAMILY)
