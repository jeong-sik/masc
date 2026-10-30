#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location("slug", pathlib.Path("slug.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
assert mod.slugify("Hello, World!") == "hello-world", mod.slugify("Hello, World!")
assert mod.slugify("  MASC eval 01 ") == "masc-eval-01", mod.slugify("  MASC eval 01 ")
assert mod.slugify("---") == "", repr(mod.slugify("---"))
print("PASS")
PY
