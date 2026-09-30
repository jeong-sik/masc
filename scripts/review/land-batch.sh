#!/usr/bin/env bash
# Keeper-only batch landing. Coding-agent sessions may use --check-only.
# No CI dispatch, retries, polling, admin bypass or automatic rule adoption.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$here/batch_evidence.py" "$@"
