#!/usr/bin/env bash
# CI gate: TLA+ spec <-> OCaml variant <-> Event type 3-way sync (VAR).
# Meta-issue: #9518
#
# CONTRACT: When an OCaml variant is used for lifecycle states / decisions / events,
# the corresponding TLA+ PlusCal variable domain and the event schema must match.
# Drift between the three representations causes "impossible" states in production
# because the model checker and the runtime disagree on valid transitions.
#
# This gate runs scripts/check-variants.sh for the full cross-language diff
# (OCaml <-> TypeScript), then performs additional TLA+-specific heuristics.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

exit_code=0

# ── 1. Full cross-language variant diff (OCaml <-> TypeScript) ────────────────
echo "=== VAR gate: cross-language variant sync (scripts/check-variants.sh) ==="
if bash scripts/check-variants.sh; then
  echo "Cross-language check: PASS"
else
  exit_code=1
fi

# ── 2. Collect OCaml variant constructors for known lifecycle types ────────────
echo ""
echo "=== Scan: OCaml lifecycle variants ==="
lifecycle_variants=$(
  rg '^\s*\|\s+([A-Z][a-zA-Z_0-9]*)' lib/keeper/keeper_types.ml \
    --type ml -o -r '$1' 2>/dev/null | sort -u || true
)
echo "  Found $(echo "$lifecycle_variants" | grep -c . || true) constructors"

# ── 3. Collect TLA+ variable domain literals (heuristic: strings in PlusCal) ──
echo ""
echo "=== Scan: TLA+ lifecycle domain literals ==="
tla_domains=$(
  rg '"([A-Z][a-zA-Z_0-9]*)"' specs/ --type tla -o -r '$1' 2>/dev/null | sort -u || true
)
echo "  Found $(echo "$tla_domains" | grep -c . || true) PascalCase literals"

# ── 4. Collect event type strings from JSON schema or event modules ────────────
echo ""
echo "=== Scan: Event type strings ==="
event_types=$(
  rg 'type.*=.*"([a-z_]+)"' lib/event_*.ml --type ml -o -r '$1' 2>/dev/null | sort -u || true
)
if [ -n "$event_types" ]; then
  echo "  Found $(echo "$event_types" | grep -c . || true) event type strings"
fi

# ── 5. TLA+ vs OCaml diff (heuristic: PascalCase TLA+ literal vs constructor) ─
if [ -n "$tla_domains" ] && [ -n "$lifecycle_variants" ]; then
  only_in_tla=$(comm -23 <(echo "$tla_domains") <(echo "$lifecycle_variants") | grep -v '^$' || true)
  if [ -n "$only_in_tla" ]; then
    echo ""
    echo "WARN: TLA+ PascalCase literals not found as OCaml constructors (drift risk):"
    echo "$only_in_tla" | sed 's/^/  /'
    echo "  (This is a heuristic match — PascalCase TLA+ may map to snake_case OCaml.)"
    echo "  (Run 'make check-variants' for the authoritative per-type check.)"
  fi
fi

# ── 6. Flag OCaml files without corresponding TLA+ spec ───────────────────────
for variant_file in lib/keeper/keeper_types.ml lib/keeper/keeper_types_profile.ml; do
  if [ -f "$variant_file" ]; then
    base=$(basename "$variant_file" .ml)
    if [ ! -f "specs/${base}.tla" ]; then
      echo "INFO: $variant_file has no matching specs/${base}.tla (not required, but note for 3-way sync)"
    fi
  fi
done

# ── 7. Wildcard match audit: flag unexplained _ wildcards in match expressions ─
echo ""
echo "=== Scan: unexplained wildcard _ in match expressions ==="
# A wildcard in a match is only acceptable with a justification comment.
# Heuristic: flag `| _ ->` lines that have no inline comment on the same line.
unexplained_wildcards=$(
  rg '^\s*\|\s+_\s*->' lib/keeper/ --type ml -n 2>/dev/null \
    | grep -v '(\*' || true
)
if [ -n "$unexplained_wildcards" ]; then
  echo "WARN: unexplained wildcard match arms in keeper lib (add justification comment):"
  echo "$unexplained_wildcards" | head -20 | sed 's/^/  /' || true
  echo "  (Consider replacing with exhaustive match; if _ is intentional, add (* justification: ... *))"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [ "$exit_code" -eq 0 ]; then
  echo "=== VAR gate: PASS (no critical drift detected) ==="
else
  echo "=== VAR gate: FAIL ==="
fi

exit "$exit_code"
