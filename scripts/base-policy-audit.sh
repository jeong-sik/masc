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
BASELINE_REF=""
FAIL_ON_REGRESSION=0

usage() {
  cat <<'EOF'
Usage: scripts/base-policy-audit.sh [options]

Options:
  --json-out <path>        Write machine-readable JSON to <path>
  --baseline-file <path>   Baseline JSON (default: .ci/health-baseline.json)
  --baseline-ref <git-ref> Read the baseline file from a git ref
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
    --baseline-ref)
      BASELINE_REF="${2:-}"
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

OPEN_BASE_DIRECTIVE_RE='^[[:space:]]*open[[:space:]]+Base([^[:alnum:]_]|$)'
STDLIB_LIST_SHADOW_RE='^[[:space:]]*module[[:space:]]+List[[:space:]]*=[[:space:]]*Stdlib\.List([^[:alnum:]_]|$)'

# Number of .mli files in lib/ that contain an actual "open Base" directive.
count_mli_open_base() {
  local count=0
  while IFS= read -r _file; do
    count=$((count + 1))
  done < <(rg -l "$OPEN_BASE_DIRECTIVE_RE" lib/ -g '*.mli' 2>/dev/null)
  printf '%s' "$count"
}

# Number of .ml files in lib/ that contain both an actual "open Base"
# directive and the Stdlib-shadow anti-pattern.
count_ml_base_stdlib_shadow() {
  local count=0
  while IFS= read -r file; do
    if rg -q "$STDLIB_LIST_SHADOW_RE" "$file" 2>/dev/null; then
      count=$((count + 1))
    fi
  done < <(rg -l "$OPEN_BASE_DIRECTIVE_RE" lib/ -g '*.ml' 2>/dev/null)
  printf '%s' "$count"
}

# Read a single numeric key from a JSON baseline file.
extract_baseline_value() {
  local file="$1"
  local key="$2"
  local default_value="$3"
  if [ ! -f "$file" ]; then
    echo "$default_value"
    return
  fi
  python3 - "$file" "$key" "$default_value" <<'PY'
import json, sys
path, key, default_value = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    with open(path) as f:
        data = json.load(f)
except Exception as exc:
    print(f"ERROR: failed to read baseline JSON {path}: {exc}", file=sys.stderr)
    sys.exit(2)

counts = data.get("counts", {})
if not isinstance(counts, dict):
    print(f"ERROR: baseline JSON {path} has no object counts field", file=sys.stderr)
    sys.exit(2)
if key not in counts:
    print(default_value)
    sys.exit(0)
try:
    print(int(counts[key]))
except Exception as exc:
    print(f"ERROR: baseline key {key} in {path} is not an integer: {exc}", file=sys.stderr)
    sys.exit(2)
PY
}

# Resolve effective baseline file: prefer --baseline-ref over --baseline-file.
BASELINE_TMP=""
cleanup() {
  if [ -n "$BASELINE_TMP" ]; then
    rm -rf "$BASELINE_TMP"
  fi
}
trap cleanup EXIT

if [ -n "$BASELINE_REF" ]; then
  ref_content="$(git show "${BASELINE_REF}:${BASELINE_FILE}" 2>/dev/null || true)"
  if [ -n "$ref_content" ]; then
    BASELINE_TMP="$(mktemp)"
    printf '%s\n' "$ref_content" > "$BASELINE_TMP"
    BASELINE_FILE="$BASELINE_TMP"
  else
    echo "ERROR: could not read baseline from ref '${BASELINE_REF}:${BASELINE_FILE}'" >&2
    exit 2
  fi
fi

# ── Collect counts ───────────────────────────────────────────────────

mli_open_base="$(count_mli_open_base)"
ml_base_stdlib_shadow="$(count_ml_base_stdlib_shadow)"

baseline_mli_open_base="$(extract_baseline_value "$BASELINE_FILE" "mli_open_base" "$mli_open_base")"
baseline_ml_base_stdlib_shadow="$(extract_baseline_value "$BASELINE_FILE" "ml_base_stdlib_shadow" "$ml_base_stdlib_shadow")"

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
