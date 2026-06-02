#!/usr/bin/env bash
# Audit exhaustive matches on cross-module variants.
#
# Issue #10584: variant-extending PRs in module A do not see exhaustive
# match sites in module B/C/D, so adding a constructor breaks `main`
# the moment the upstream variant ships (e.g. #10490 InferenceTelemetry,
# #10574 Stale_turn_timeout). Build's -warn-error catches it, but only
# AFTER the variant lands on main.
#
# This script implements Option C from the issue: it does NOT enforce
# anything. It scans for `match Module.expr with` patterns and surfaces
# them as candidate sites that PR reviewers / authors should consider
# adding a defensive arm to (or migrating to a source-of-truth converter
# in the type's own module — Option B).
#
# Always exits 0; treat output as informational.
#
# Usage:
#   scripts/audit-cross-module-exhaustive-match.sh           # default: stdout
#   scripts/audit-cross-module-exhaustive-match.sh --counts  # per-source summary
#
# Tracked source-of-truth modules can be extended via $EXTRA_MATCH_SOURCES
# (whitespace-separated list of module-prefix patterns suitable for ripgrep).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Modules whose variants have historically broken main when extended.
# Order matches the issue's "Concrete sites to audit" list.
MATCH_SOURCES=(
  'Oas\.Event_bus\.'
  'Oas\.Error\.'
  'Keeper_registry\.'
  'Keeper_types\.'
  ${EXTRA_MATCH_SOURCES:-}
)

MODE="list"
case "${1:-}" in
  ""|--list) MODE="list" ;;
  --counts)  MODE="counts" ;;
  -h|--help)
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac

if ! command -v rg >/dev/null 2>&1; then
  echo "ripgrep (rg) is required" >&2
  exit 2
fi

cd "$REPO_ROOT"

scan_one() {
  # Match arms of the form `| Module.Constructor` (constructor =
  # capital letter after the dot). Plain function calls
  # `Module.lowercase_fn` do not match. The two-line context is
  # ripgrep's `--multiline` so we still find single-line matches
  # with `| Module.Foo -> ...`.
  local pattern="$1"
  rg -n --no-heading --type ml "\\|[[:space:]]*${pattern}[A-Z]" lib/ \
    2>/dev/null \
    | grep -v '/test/' || true
}

case "$MODE" in
  list)
    for src in "${MATCH_SOURCES[@]}"; do
      [ -z "$src" ] && continue
      hits="$(scan_one "$src")"
      [ -z "$hits" ] && continue
      printf '\n=== source: %s ===\n' "$src"
      printf '%s\n' "$hits"
    done
    ;;
  counts)
    printf '%-32s %s\n' "source pattern" "site count"
    printf '%-32s %s\n' "--------------" "----------"
    for src in "${MATCH_SOURCES[@]}"; do
      [ -z "$src" ] && continue
      n="$(scan_one "$src" | wc -l | tr -d ' ')"
      printf '%-32s %s\n' "$src" "$n"
    done
    ;;
esac
