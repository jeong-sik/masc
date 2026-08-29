#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location("wordcount", pathlib.Path("wordcount.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
assert mod.word_counts("a b a") == {"a": 2, "b": 1}, mod.word_counts("a b a")
assert mod.word_counts("The the  THE") == {"the": 3}, mod.word_counts("The the  THE")
assert mod.word_counts("") == {}, mod.word_counts("")
print("PASS")
PY
