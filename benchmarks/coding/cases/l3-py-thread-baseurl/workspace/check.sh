#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import sys; sys.path.insert(0, ".")
import client
assert client.endpoint("/v1/items") == "https://api.example.com/v1/items", client.endpoint("/v1/items")
assert client.endpoint("") == "https://api.example.com", client.endpoint("")
print("PASS")
PY
