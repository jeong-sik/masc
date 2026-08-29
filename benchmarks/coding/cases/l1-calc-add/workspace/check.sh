#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Without this, a first (failing) check writes __pycache__, and a fix that
# keeps calc.py the same byte size within the same mtime second revalidates
# the stale bytecode — the check would keep failing after a correct edit.
export PYTHONDONTWRITEBYTECODE=1

python3 - <<'PY'
import importlib.util
import pathlib

path = pathlib.Path("calc.py")
spec = importlib.util.spec_from_file_location("calc", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
value = module.add_two_and_three()
assert value == 5, f"expected 5, got {value}"
print("PASS")
PY
