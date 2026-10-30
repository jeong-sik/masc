#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location("reverse", pathlib.Path("reverse.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
assert mod.reverse("abc") == "cba", mod.reverse("abc")
assert mod.reverse("") == "", repr(mod.reverse(""))
assert mod.reverse("racecar") == "racecar", mod.reverse("racecar")
print("PASS")
PY
