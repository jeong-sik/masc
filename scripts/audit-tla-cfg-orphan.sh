#!/usr/bin/env bash
# audit-tla-cfg-orphan.sh — one-shot audit for cfg ↔ spec orphan references.
#
# Detects the 5th TLA+ drift class identified in iter 44 audit
# (`docs/tla-audit/kdp-cap2-dead-cfg-2026-05-12.md`): cfg files referencing
# INVARIANTS or PROPERTIES that are not defined in their parent .tla.
#
# This is an *audit-mode* tool, intentionally NOT wired into CI.  Iter 45
# R-F-2 full-corpus sweep (200 cfgs across 18 spec dirs) found exactly 3
# orphans, all in a single cfg pair (KeeperDecisionPipeline-cap2.cfg),
# already closed by iter 45 PR #14843.  CI integration (R-F-1.c) is
# deferred until evidence of a recurring pattern emerges.
#
# Usage:
#   bash scripts/audit-tla-cfg-orphan.sh
#
# Exit codes:
#   0  no orphans
#   1  orphans found (printed to stdout)
#   2  invalid environment
#
# Coverage: scans every `.cfg` under specs/, derives the parent `.tla` by
# progressively stripping `-<suffix>` tokens from the cfg basename until
# a sibling `.tla` is found, then checks each INVARIANTS/PROPERTIES name
# against the parent.  Orphan CONSTANTS are tolerated by TLC and not
# checked here (intentional — TLC's own error-surface asymmetry treats
# them as silent, see iter 44 audit §"Empirical observations").
#
# Limitations:
#   - Does not parse TLA+ EXTENDS chains — names imported via `EXTENDS`
#     would be flagged as orphan.  Add explicit extension-aware lookup
#     if false positives appear.
#   - Suffix-stripping heuristic relies on `-`-delimited tokens.  If a
#     spec author uses `_` or no separator for cfg variants, the
#     parent lookup will SKIP.

set -u

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

if [[ ! -d specs ]]; then
  echo "error: specs/ not found at $REPO_ROOT" >&2
  exit 2
fi

ORPHANS=0
CHECKED=0
SKIPPED=0

for cfg in $(find specs -name "*.cfg" | sort); do
  base=$(basename "$cfg" .cfg)
  dir=$(dirname "$cfg")
  parent="$base"
  tla="$dir/$parent.tla"
  while [[ ! -f "$tla" ]] && [[ -n "$parent" ]]; do
    new_parent=$(echo "$parent" | sed -E 's/-[^-]+$//')
    [[ "$new_parent" == "$parent" ]] && break
    parent="$new_parent"
    tla="$dir/$parent.tla"
  done
  if [[ ! -f "$tla" ]]; then
    SKIPPED=$((SKIPPED+1))
    continue
  fi
  CHECKED=$((CHECKED+1))
  names=$(awk '
    /^INVARIANTS|^PROPERTIES/ { in_block=1; next }
    /^CONSTANTS|^SPECIFICATION|^CHECK_DEADLOCK|^INIT|^NEXT/ { in_block=0 }
    in_block && /^[[:space:]]+[A-Za-z]/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      print
    }
  ' "$cfg")
  for name in $names; do
    if ! rg -q "\b${name}\b" "$tla"; then
      printf "ORPHAN %s -> %s: %s\n" "$cfg" "$(basename "$tla")" "$name"
      ORPHANS=$((ORPHANS+1))
    fi
  done
done

echo "---"
printf "audit-tla-cfg-orphan summary: %d cfgs scanned / %d skipped (no parent) / %d orphans\n" \
  "$CHECKED" "$SKIPPED" "$ORPHANS"

if [[ $ORPHANS -gt 0 ]]; then
  echo ""
  echo "Fix: either (a) add the named invariant/property to the parent .tla,"
  echo "or (b) remove the orphan reference from the cfg, or (c) delete the"
  echo "cfg if it has never been executable (iter 45 #14843 R-F-1.a precedent)."
  exit 1
fi

exit 0
