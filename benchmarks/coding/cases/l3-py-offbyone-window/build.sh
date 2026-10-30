#!/usr/bin/env bash
set -euo pipefail
cd "$1"
export PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import sys; sys.path.insert(0, ".")
import window  # noqa: F401
PY
