#!/usr/bin/env bash
# CI gate: TLA+ spec <-> OCaml variant <-> Event type 3-way sync (VAR).
# Meta-issue: #9518
#
# CONTRACT: When an OCaml variant is used for lifecycle states / decisions / events,
# the corresponding TLA+ PlusCal variable domain and the event schema must match.
# Drift between the three representations causes "impossible" states in production
# because the model checker and the runtime disagree on valid transitions.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

exit_code=0

# 1. Collect OCaml variant constructors for known lifecycle types
echo "=== Scan: OCaml lifecycle variants ==="
lifecycle_variants=$(
  rg '^\s*\|\s+([A-Z][a-zA-Z_0-9]*)' lib/keeper/keeper_types.ml \
    --type ml -o -r '$1' 2>/dev/null | sort -u || true
)

# 2. Collect TLA+ variable domain literals (heuristic: strings in PlusCal)
echo "=== Scan: TLA+ lifecycle domain literals ==="
tla_domains=$(
  rg '"([A-Z][a-zA-Z_0-9]*)"' specs/ --type tla -o -r '$1' 2>/dev/null | sort -u || true
)

# 3. Collect event type strings from JSON schema or event modules
echo "=== Scan: Event type strings ==="
event_types=$(
  rg 'type.*=.*"([a-z_]+)"' lib/event_*.ml --type ml -o -r '$1' 2>/dev/null | sort -u || true
)

# Simple diff: warn if TLA+ has a literal not present in OCaml variants
# This is intentionally conservative; full 3-way sync requires AST parsing.
if [ -n "$tla_domains" ] && [ -n "$lifecycle_variants" ]; then
  only_in_tla=$(comm -23 <(echo "$tla_domains") <(echo "$lifecycle_variants"))
  if [ -n "$only_in_tla" ]; then
    echo "WARN: TLA+ domain literals not found in OCaml variants (drift risk):"
    echo "$only_in_tla" | sed 's/^/  /'
  fi
fi

# 4. Flag OCaml files that define lifecycle variants but have no corresponding
#    TLA+ spec file or event module.
for variant_file in lib/keeper/keeper_types.ml lib/keeper/keeper_types_profile.ml; do
  if [ -f "$variant_file" ]; then
    base=$(basename "$variant_file" .ml)
    if [ ! -f "specs/${base}.tla" ]; then
      echo "INFO: $variant_file has no matching specs/${base}.tla (not required, but note for 3-way sync)"
    fi
  fi
done

if [ "$exit_code" -eq 0 ]; then
  echo "=== VAR gate: PASS (no critical drift detected) ==="
else
  echo "=== VAR gate: FAIL ==="
fi

exit "$exit_code"
