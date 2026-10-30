#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import sys; sys.path.insert(0, ".")
import importlib, store, inventory
importlib.reload(store); importlib.reload(inventory)
# warm(1) + three puts = 4 distinct keys
assert inventory.build_inventory([("a",1),("b",2),("c",3)]) == 4, inventory.build_inventory([("a",1),("b",2),("c",3)])
# direct: warm the cache, then put, size must update
s = store.Store()
s.put("x", 1)
assert s.size() == 1
s.put("y", 2)
assert s.size() == 2, "size() returned a stale cached value after put"
s.delete("x")
assert s.size() == 1, "size() stale after delete"
print("PASS")
PY
