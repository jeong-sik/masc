#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import sys; sys.path.insert(0, ".")
import rle
assert rle.encode("aaab") == "a3b1", rle.encode("aaab")
assert rle.encode("") == "", repr(rle.encode(""))
assert rle.encode("abc") == "a1b1c1", rle.encode("abc")
print("PASS")
PY
