#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import sys; sys.path.insert(0, ".")
import registry
assert registry.add_item("a") == ["a"], registry.add_item("a")
assert registry.add_item("b") == ["b"], "default bucket leaked across calls"
shared = []
assert registry.add_item("x", shared) == ["x"]
assert registry.add_item("y", shared) == ["x", "y"], "explicit bucket should accumulate"
print("PASS")
PY
