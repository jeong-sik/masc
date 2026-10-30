#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export PYTHONDONTWRITEBYTECODE=1
[ "$(python3 main.py)" = "TOTAL: 3300won" ]
echo PASS
