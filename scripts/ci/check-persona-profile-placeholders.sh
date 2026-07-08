#!/usr/bin/env bash
# Build-time check: reject OPERATOR_TODO placeholders in source code and profiles.
# This prevents deployment of code with unresolved placeholders.
set -euo pipefail

marker="OPERATOR_TODO"
root="${1:-.}"

if ! command -v rg >/dev/null 2>&1; then
  echo "::error::ripgrep (rg) is required to check OPERATOR_TODO source markers"
  exit 1
fi

# Check OCaml source files for OPERATOR_TODO markers
# Exclude the marker definition itself and test files
hits=$(rg -n --fixed-strings "$marker" "$root" \
  --glob '**/*.ml' --glob '**/*.mli' \
  --glob '!**/test_*.ml' --glob '!**/*_test.ml' \
  --glob '!**/keeper_types_profile_persona.ml' 2>/dev/null || true)

if [ -n "$hits" ]; then
  echo "::error::OPERATOR_TODO placeholder marker '$marker' must not be present in source code"
  echo "$hits"
  echo "::error::Replace all OPERATOR_TODO placeholders with concrete values before committing"
  exit 1
fi

# Also check JSON profile files
if [ -d "config/personas" ]; then
  profile_hits=$(rg -n --fixed-strings "$marker" "config/personas" --glob '**/profile.json' 2>/dev/null || true)
  if [ -n "$profile_hits" ]; then
    echo "::error::OPERATOR_TODO placeholder marker '$marker' must not be present in persona profiles"
    echo "$profile_hits"
    exit 1
  fi
fi
