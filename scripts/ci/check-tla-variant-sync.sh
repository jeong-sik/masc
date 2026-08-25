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
# The last three used to be listed under lib/keeper_registry_types_<x>/ —
# directories that do not exist. rg skipped them silently (2>/dev/null) and the
# OCaml side of the comparison was built from two files instead of five.
variant_sources=(
  lib/keeper_types/keeper_types.ml
  lib/keeper/keeper_registry_types.ml
  lib/keeper_registry/keeper_registry_types_turn_phase.ml
  lib/keeper_registry/keeper_registry_types_decision.ml
  lib/keeper_registry/keeper_registry_types_compaction.ml
)
for src in "${variant_sources[@]}"; do
  if [ ! -f "$src" ]; then
    echo "FAIL: variant source $src not found — the OCaml side of the scan is incomplete"
    exit 1
  fi
done
lifecycle_variants=$(
  rg '^\s*\|\s+([A-Z][a-zA-Z_0-9]*)' \
    "${variant_sources[@]}" \
    --type ml -o -r '$1' 2>/dev/null | sort -u || true
)
echo "  Found $(echo "$lifecycle_variants" | grep -c . || true) constructors"

# ── 3. Collect TLA+ variable domain literals (heuristic: strings in PlusCal) ──
echo ""
echo "=== Scan: TLA+ lifecycle domain literals ==="
# ripgrep has no built-in "tla" file type: --type tla exits with
# "unrecognized file type", 2>/dev/null hid the message and || true turned the
# failure into an empty set. This scan reported "Found 0 PascalCase literals"
# on every run since it was written, so section 5 below -- guarded on this
# being non-empty -- never compared anything. A glob reads the same files.
tla_domains=$(
  rg '"([A-Z][a-zA-Z_0-9]*)"' specs/ --glob '*.tla' --no-filename -o -r '$1' 2>/dev/null | sort -u || true
)
if [ -z "$tla_domains" ]; then
  echo "FAIL: no PascalCase literals found under specs/ — the scan is not reading the specs"
  exit 1
fi
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

# Section 5 used to diff the two sets above and WARN on PascalCase literals
# with no matching OCaml constructor. It never ran -- the TLA+ side was empty
# because of the --type tla bug -- and it cannot be turned on as written: the
# OCaml side samples five keeper-registry files while the TLA+ side spans all
# 42 specs, so constructors that live elsewhere (Masc_domain's Claimed,
# Cancelled, ...) read as drift. All 70 literals report. Its own text already
# deferred to check-variants.sh for "the authoritative per-type check", and
# that script does the comparison properly, per type, with the spec named.
# The counts above stay: they are now true, which is the point of this change.

# ── 6. Flag OCaml files without corresponding TLA+ spec ───────────────────────
for variant_file in lib/keeper_types/keeper_types.ml lib/keeper/keeper_types_profile.ml; do
  if [ -f "$variant_file" ]; then
    base=$(basename "$variant_file" .ml)
    # Specs live in subdirectories (specs/keeper-state-machine/..., specs/auth/...),
    # so the flat specs/<base>.tla path this used to test could never exist and
    # the INFO fired regardless of what is on disk.
    if [ -z "$(find specs -name "${base}.tla" -print -quit 2>/dev/null)" ]; then
      echo "INFO: $variant_file has no matching ${base}.tla under specs/ (not required, but note for 3-way sync)"
    fi
  fi
done

# ── 7. Wildcard match audit: flag unexplained _ wildcards in match expressions ─
echo ""
echo "=== Scan: unexplained wildcard _ in match expressions ==="
# A wildcard in a match is only acceptable with a justification comment.
# Heuristic: flag `| _ ->` lines that have no inline `(*` comment on the same line.
# Limitation: multi-line justification comments (on the next line) are not detected.
# If _ is intentional, add an inline comment: `| _ -> ... (* justification: ... *)`
unexplained_wildcards=$(
  rg '^\s*\|\s+_\s*->' lib/keeper/ --type ml -n 2>/dev/null \
    | grep -v -- '->.*(\*' || true
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
