#!/usr/bin/env bash
set -euo pipefail

lock_file=${1:?usage: gen-sandbox-opam-lock-sha256-ml.sh LOCK_FILE}
if command -v sha256sum >/dev/null 2>&1; then
  digest=$(sha256sum "$lock_file" | awk '{print $1}')
else
  digest=$(shasum -a 256 "$lock_file" | awk '{print $1}')
fi
printf 'let sha256 = "%s"\n' "$digest"
