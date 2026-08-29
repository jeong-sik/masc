#!/usr/bin/env bash
# Build probe: the candidate edit must at least import (compile). A red exit
# here attributes a verify-red run to Build_failed rather than Wrong_solution.
set -euo pipefail
cd "$1"
export PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import sys; sys.path.insert(0, ".")
import clamp  # noqa: F401
PY
