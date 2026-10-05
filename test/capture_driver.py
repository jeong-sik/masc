"""Run the three exact-slot refusal scenarios and print their plaintext screens.

The full lane-editor family runs sixteen scenarios and takes minutes; the
verifier asked for the picker and refusal screens at the submitted head, so
this driver imports the family and calls just those three: the default 80x24
refusal, the 80x30 crowded refusal (whose row budget binds), and the picker
refusal. Set MASC_CAPTURE_REFUSAL=1 so each scenario prints its screen.
"""

import os
import sys

sys.path.insert(0, os.path.abspath("."))
import test_tui_runtime_lane_editor as family  # noqa: E402

executable = os.path.abspath(sys.argv[1])
family.run_exact_refusal(executable)
family.run_exact_refusal_crowded(executable)
family.run_exact_picker_refusal(executable)
print("capture driver: PASS")
