#!/usr/bin/env bash
set -euo pipefail
workspace="$1"
cd "${workspace}"
python3 check.py
