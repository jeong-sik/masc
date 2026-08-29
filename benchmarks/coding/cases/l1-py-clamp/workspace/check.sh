#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import sys; sys.path.insert(0, ".")
import clamp
assert clamp.clamp(5, 0, 10) == 5, clamp.clamp(5, 0, 10)
assert clamp.clamp(-3, 0, 10) == 0, clamp.clamp(-3, 0, 10)
assert clamp.clamp(42, 0, 10) == 10, clamp.clamp(42, 0, 10)
print("PASS")
PY
