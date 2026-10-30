#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import sys; sys.path.insert(0, ".")
import parsekv
assert parsekv.parse_kv("a=1\nb=2") == {"a": "1", "b": "2"}, parsekv.parse_kv("a=1\nb=2")
assert parsekv.parse_kv("a=1\n\na=2") == {"a": "2"}, parsekv.parse_kv("a=1\n\na=2")
assert parsekv.parse_kv("") == {}, parsekv.parse_kv("")
print("PASS")
PY
