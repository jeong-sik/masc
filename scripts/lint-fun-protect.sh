#!/usr/bin/env bash
# lint-fun-protect.sh — Block bare Fun.protect in lib/ (use Eio_guard.protect instead)
# Exit 1 if any bare Fun.protect found that isn't already Eio_guard.protect

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Files that are allowed to use Fun.protect (Eio_guard.ml itself, tests)
ALLOWLIST=(
  "lib/core/eio_guard.ml"
)

count=0
while IFS= read -r line; do
  file=$(echo "$line" | cut -d: -f1)

  # Skip allowlisted files
  for allowed in "${ALLOWLIST[@]}"; do
    if [[ "$file" == "$allowed" ]]; then
      continue 2
    fi
  done

  # Skip if it's Eio_guard.protect (already migrated)
  if echo "$line" | grep -q "Eio_guard\.protect"; then
    continue
  fi

  echo "ERROR: bare Fun.protect found (use Eio_guard.protect instead): $line"
  count=$((count + 1))
done < <(rg "Fun\.protect" lib/ --line-number 2>/dev/null || true)

if [[ $count -gt 0 ]]; then
  echo ""
  echo "Found $count bare Fun.protect usage(s). Replace with Eio_guard.protect."
  echo "See issue #10395 for migration guide."
  exit 1
fi

echo "OK: no bare Fun.protect found in lib/"
exit 0
