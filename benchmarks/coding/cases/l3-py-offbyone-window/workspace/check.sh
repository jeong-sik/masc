#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import sys; sys.path.insert(0, ".")
import window
assert window.max_in_windows([1,3,-1,-3,5,3,6,7], 3) == [3,3,5,5,6,7], window.max_in_windows([1,3,-1,-3,5,3,6,7], 3)
assert window.max_in_windows([4,2], 2) == [4], window.max_in_windows([4,2], 2)
assert window.max_in_windows([9], 1) == [9], window.max_in_windows([9], 1)
assert window.max_in_windows([1,2,3,4,5], 5) == [5], window.max_in_windows([1,2,3,4,5], 5)
print("PASS")
PY
