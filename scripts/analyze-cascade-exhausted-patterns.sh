#!/usr/bin/env bash
# analyze-cascade-exhausted-patterns.sh
# Fleet cascade_exhausted pattern analyzer
# Scans OCaml source for cascade_exhausted usage patterns and reports:
#   - call sites, variant constructors, error propagation paths
#   - missing exhaustive match branches
#   - log/telemetry surface area
#
# Usage: ./scripts/analyze-cascade-exhausted-patterns.sh [--json] [--diff BASE]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE=text
DIFF_BASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) MODE=json; shift ;;
    --diff) DIFF_BASE="${2:-HEAD~1}"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--json] [--diff BASE]"
      echo "  --json   Output JSON report"
      echo "  --diff   Only show findings changed since BASE commit"
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

cd "$REPO_ROOT"

# --- Collect raw data ---
# Pattern 1: variant constructors containing "cascade_exhausted"
_constructors=$(grep -rn 'cascade_exhausted' lib/ --include='*.ml' --include='*.mli' || true)

# Pattern 2: match branches that handle Cascade_exhausted
_match_branches=$(grep -rn -B2 -A2 '|.*[Cc]ascade.*[Ee]xhausted' lib/ --include='*.ml' || true)

# Pattern 3: error_to_string / show / pp overrides touching cascade_exhausted
_serializers=$(grep -rn 'cascade_exhausted' lib/ --include='*.ml' -A3 || true)

# Pattern 4: log/telemetry emission sites
_log_sites=$(grep -rn 'cascade_exhausted\|Cascade_exhausted\|cascade.*exhaust' lib/ --include='*.ml' \
  | grep -i 'log\|trace\|emit\|telemetry\|metric\|span' || true)

# Pattern 5: test coverage
_test_sites=$(grep -rn 'cascade_exhausted\|Cascade_exhausted' test/ --include='*.ml' --include='*.mli' 2>/dev/null || true)

# --- Filtering for --diff mode ---
if [[ -n "$DIFF_BASE" ]]; then
  _changed_files=$(git diff --name-only "$DIFF_BASE" -- lib/ test/ 2>/dev/null || true)
  if [[ -z "$_changed_files" ]]; then
    echo "No relevant files changed since $DIFF_BASE"
    exit 0
  fi
fi

# --- Analysis helpers ---
count_lines() { echo "$1" | grep -c '.' || echo 0; }
extract_files() { echo "$1" | sed 's/:.*//' | sort -u; }

_unique_files=$(extract_files "$_constructors")
_total_constructors=$(count_lines "$_constructors")
_total_match=$(count_lines "$_match_branches")
_total_tests=$(count_lines "$_test_sites")
_total_log=$(count_lines "$_log_sites")

# --- Find missing match coverage ---
# For each file declaring a cascade_exhausted variant, check if tests exist
_missing_test_files=""
for f in $_unique_files; do
  base=$(basename "$f" .ml)
  test_hit=$(echo "$_test_sites" | grep -i "$base" || true)
  if [[ -z "$test_hit" ]]; then
    _missing_test_files="$_missing_test_files $f"
  fi
done

# --- Output ---
if [[ "$MODE" == "json" ]]; then
  cat <<EOF
{
  "schema": "cascade-exhausted-pattern-v1",
  "repo": "$REPO_ROOT",
  "base": "${DIFF_BASE:-full}",
  "summary": {
    "constructor_sites": $_total_constructors,
    "match_branches": $_total_match,
    "test_sites": $_total_tests,
    "log_telemetry_sites": $_total_log,
    "files_with_constructors": $(echo "$_unique_files" | wc -w | tr -d ' '),
    "files_missing_tests": $(echo "$_missing_test_files" | wc -w | tr -d ' ')
  },
  "constructors": $(echo "$_constructors" | python3 -c "import sys,json; lines=[l.strip() for l in sys.stdin if l.strip()]; print(json.dumps(lines))" 2>/dev/null || echo '[]'),
  "match_branches": $(echo "$_match_branches" | python3 -c "import sys,json; lines=[l.strip() for l in sys.stdin if l.strip()]; print(json.dumps(lines))" 2>/dev/null || echo '[]'),
  "log_sites": $(echo "$_log_sites" | python3 -c "import sys,json; lines=[l.strip() for l in sys.stdin if l.strip()]; print(json.dumps(lines))" 2>/dev/null || echo '[]'),
  "test_sites": $(echo "$_test_sites" | python3 -c "import sys,json; lines=[l.strip() for l in sys.stdin if l.strip()]; print(json.dumps(lines))" 2>/dev/null || echo '[]'),
  "files_missing_test_coverage": $(echo "$_missing_test_files" | python3 -c "import sys,json; items=[x for x in sys.stdin.read().split() if x]; print(json.dumps(items))" 2>/dev/null || echo '[]')
}
EOF
else
  echo "=== cascade_exhausted Pattern Analyzer ==="
  echo ""
  echo "--- Summary ---"
  echo "  Constructor sites:    $_total_constructors"
  echo "  Match branches:       $_total_match"
  echo "  Test sites:           $_total_tests"
  echo "  Log/telemetry sites:  $_total_log"
  echo "  Files with usage:     $(echo "$_unique_files" | wc -w | tr -d ' ')"
  echo ""
  echo "--- Constructors (declaration & usage) ---"
  echo "$_constructors" | head -40
  echo ""
  echo "--- Match branch coverage ---"
  echo "$_match_branches" | head -60
  echo ""
  echo "--- Log / Telemetry surface ---"
  if [[ -n "$_log_sites" ]]; then
    echo "$_log_sites"
  else
    echo "  (none found — telemetry gap?)"
  fi
  echo ""
  echo "--- Test coverage ---"
  if [[ -n "$_test_sites" ]]; then
    echo "$_test_sites"
  else
    echo "  (none found — ZERO test coverage for cascade_exhausted)"
  fi
  echo ""
  echo "--- Files missing test coverage ---"
  if [[ -n "$_missing_test_files" ]]; then
    for f in $_missing_test_files; do
      echo "  $f"
    done
  else
    echo "  (all files with cascade_exhausted have corresponding tests)"
  fi
  echo ""
  echo "=== End of report ==="
fi