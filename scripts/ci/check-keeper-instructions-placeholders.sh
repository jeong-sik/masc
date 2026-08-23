#!/usr/bin/env bash
# Build-time check: reject OPERATOR_TODO placeholders in source and Keeper prompts.
set -euo pipefail

marker="OPERATOR_TODO"
root="${1:-.}"

if ! command -v rg >/dev/null 2>&1; then
  echo "::error::ripgrep (rg) is required to check OPERATOR_TODO source markers"
  exit 1
fi

hits=$(rg -n --fixed-strings "$marker" "$root" \
  --glob '**/*.ml' --glob '**/*.mli' \
  --glob '!test/**' --glob '!**/test_*.ml' --glob '!**/*_test.ml' \
  --glob '!**/keeper_types_profile.ml' 2>/dev/null || true)

if [ -n "$hits" ]; then
  echo "::error::OPERATOR_TODO placeholder marker '$marker' must not be present in source code"
  echo "$hits"
  exit 1
fi

for keepers_dir in config/keepers presets/*/keepers; do
  if [ -d "$keepers_dir" ]; then
    instruction_hits=$(rg -n --fixed-strings "$marker" "$keepers_dir" --glob '*.toml' 2>/dev/null || true)
    if [ -n "$instruction_hits" ]; then
      echo "::error::OPERATOR_TODO placeholder marker '$marker' must not be present in Keeper TOML instructions"
      echo "$instruction_hits"
      exit 1
    fi
  fi
done
