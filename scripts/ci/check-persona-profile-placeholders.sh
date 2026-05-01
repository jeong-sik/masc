#!/usr/bin/env bash
set -euo pipefail

root="${1:-config/personas}"
marker="OPERATOR_TODO"

if [ ! -d "$root" ]; then
  exit 0
fi

if rg -n --fixed-strings "$marker" "$root" --glob '*/profile.json'; then
  echo "::error::persona profile placeholder marker '$marker' must not be committed under $root"
  exit 1
fi
