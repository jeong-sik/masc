#!/usr/bin/env bash
# Base Policy Audit — count open Base in .mli files and Stdlib-shadow
# anti-pattern in .ml files as defined in docs/BASE-POLICY.md.
#
# Outputs a human-readable summary plus, when --json-out is given,
# a machine-readable JSON file compatible with health_snapshot.sh.
#
# Usage:
#   scripts/base-policy-audit.sh [--json-out <path>] [--baseline-file <path>]
#                                 [--fail-on-regression] [-h|--help]
#
# Exit codes:
#   0 — audit passed (no regression vs baseline, or baseline not requested)
#   1 — regression detected (--fail-on-regression only)
#   2 — usage / dependency error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

JSON_OUT=""
BASELINE_FILE=".ci/health-baseline.json"
FAIL_ON_REGRESSION=0

usage() {
  cat <<'EOF'
Usage: scripts/base-policy-audit.sh [options]

Options:
  --json-out <path>        Write machine-readable JSON to <path>
  --baseline-file <path>   Baseline JSON (default: .ci/health-baseline.json)
  --fail-on-regression     Exit 1 when counts exceed baseline
  -h|--help                Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json-out)
      JSON_OUT="${2:-}"
      shift 2
      ;;
    --baseline-file)
      BASELINE_FILE="${2:-}"
      shift 2
      ;;
    --fail-on-regression)
      FAIL_ON_REGRESSION=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v rg >/dev/null 2>&1; then
  echo "ERROR: ripgrep (rg) is required" >&2
  exit 2
fi

# ── Counting helpers ────────────────────────────────────────────────

# Number of .mli files in lib/ that contain "open Base".
count_mli_open_base() {
  rg -l "open Base" lib/ -g '*.mli' 2>/dev/null | wc -l | tr -d ' '
}

# Number of .ml files in lib/ that contain both "open Base" AND
# "module List = Stdlib.List" (the Stdlib-shadow anti-pattern).
count_ml_base_stdlib_shadow() {
  local count=0
  while IFS= read -r file; do
    if rg -q "module List = Stdlib\.List" "$file" 2>/dev/null; then
      count=$((count + 1))
    fi
  done < <(rg -l "open Base" lib/ -g '*.ml' 2>/dev/null)
  printf '%s' "$count"
}

# Read a single numeric key from a JSON baseline file.
extract_baseline_value() {
  local file="$1"
  local key="$2"
  if [ ! -f "$file" ]; then
    echo 0
    return
  fi
  python3 - "$file" "$key" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
    print(int(data.get("counts", {}).get(key, 0)))
except Exception:
    print(0)
PY
}

# ── Collect counts ───────────────────────────────────────────────────

mli_open_base="$(count_mli_open_base)"
ml_base_stdlib_shadow="$(count_ml_base_stdlib_shadow)"

baseline_mli_open_base="$(extract_baseline_value "$BASELINE_FILE" "mli_open_base")"
baseline_ml_base_stdlib_shadow="$(extract_baseline_value "$BASELINE_FILE" "ml_base_stdlib_shadow")"

# ── Report ───────────────────────────────────────────────────────────

echo "=== Base Policy Audit ==="
echo ""
echo "  mli_open_base          : ${mli_open_base}  (baseline: ${baseline_mli_open_base})"
echo "  ml_base_stdlib_shadow  : ${ml_base_stdlib_shadow}  (baseline: ${baseline_ml_base_stdlib_shadow})"
echo ""

regressions=()
[ "${mli_open_base}" -gt "${baseline_mli_open_base}" ] && \
  regressions+=("mli_open_base ${baseline_mli_open_base}->${mli_open_base}")
[ "${ml_base_stdlib_shadow}" -gt "${baseline_ml_base_stdlib_shadow}" ] && \
  regressions+=("ml_base_stdlib_shadow ${baseline_ml_base_stdlib_shadow}->${ml_base_stdlib_shadow}")

if [ "${#regressions[@]}" -eq 0 ]; then
  echo "  Status: PASS"
else
  echo "  Status: REGRESSION"
  for r in "${regressions[@]}"; do
    echo "    - ${r}"
  done
fi

# ── Optional JSON output ─────────────────────────────────────────────

if [ -n "$JSON_OUT" ]; then
  mkdir -p "$(dirname "$JSON_OUT")"
  cat > "$JSON_OUT" <<EOF
{
  "mli_open_base": ${mli_open_base},
  "ml_base_stdlib_shadow": ${ml_base_stdlib_shadow},
  "baseline": {
    "mli_open_base": ${baseline_mli_open_base},
    "ml_base_stdlib_shadow": ${baseline_ml_base_stdlib_shadow}
  }
}
EOF
fi

# ── Regression gate ──────────────────────────────────────────────────

if [ "$FAIL_ON_REGRESSION" -eq 1 ] && [ "${#regressions[@]}" -gt 0 ]; then
  echo "" >&2
  echo "ERROR: Base policy regression detected.  See docs/BASE-POLICY.md." >&2
  exit 1
fi

exit 0
