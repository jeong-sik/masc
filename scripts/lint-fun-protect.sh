#!/usr/bin/env bash
# lint-fun-protect.sh — Block bare Fun.protect in lib/ (use Eio_guard.protect instead)
# Exit 1 if any bare Fun.protect found that isn't already Eio_guard.protect

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Files that are allowed to use Fun.protect (Eio_guard.ml itself, tests)
ALLOWLIST=(
  "lib/core/eio_guard.ml"
  "lib/core/eio_guard.mli"
)

count=0
while IFS= read -r line; do
  file=$(echo "$line" | cut -d: -f1)
  linenum=$(echo "$line" | cut -d: -f2)

  # Skip allowlisted files
  for allowed in "${ALLOWLIST[@]}"; do
    if [[ "$file" == "$allowed" ]]; then
      continue 2
    fi
  done

  # Skip .mli files (documentation references only, not executable code)
  if [[ "$file" == *.mli ]]; then
    continue
  fi

  # Skip if it's Eio_guard.protect (already migrated)
  if echo "$line" | grep -q "Eio_guard\.protect"; then
    continue
  fi

  # Skip if it's Stdlib.Fun.protect (explicit stdlib reference in compat modules)
  if echo "$line" | grep -q "Stdlib\.Fun\.protect"; then
    continue
  fi

  # Skip comment lines (OCaml comments start with * or are inside (* ... *))
  content=$(echo "$line" | cut -d: -f3- | sed 's/^[[:space:]]*//')
  if [[ "$content" == \(\** ]] || [[ "$content" == \*\)* ]] || [[ "$content" == \** ]]; then
    continue
  fi

  # Skip Stdlib.Mutex lock/unlock patterns (not migration targets —
  # these protect cross-thread shared state, not Eio fiber cleanup)
  if echo "$content" | grep -qE "(Stdlib\.)?Mutex\.(un)?lock"; then
    continue
  fi

  # Skip if the finally clause is purely Mutex.unlock (Mutex pattern)
  if echo "$content" | grep -qE "finally.*Mutex\.unlock"; then
    continue
  fi

  echo "ERROR: bare Fun.protect found (use Eio_guard.protect instead): $line"
  count=$((count + 1))
done < <(rg "Fun\.protect" lib/ --type ocaml --line-number 2>/dev/null || true)

if [[ $count -gt 0 ]]; then
  echo ""
  echo "Found $count bare Fun.protect usage(s). Replace with Eio_guard.protect."
  echo "See issue #10395 for migration guide."
  exit 1
fi

echo "OK: no bare Fun.protect found in lib/"
exit 0
