"""Check catalogue read scope without launching the default keyboard walk."""
from __future__ import annotations

import os
import sys

from tui_keyboard_context import run_context_catalog_read_scope


if __name__ == "__main__":
    run_context_catalog_read_scope(os.path.abspath(sys.argv[1]))
    print("Context catalogue read scope: PASS")
