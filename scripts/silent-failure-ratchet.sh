#!/usr/bin/env bash
# Silent failure ratchet gate.
#
# Tracks four metrics that count textual silent-failure shapes in
# OCaml sources under lib/. The baseline is committed to
#   scripts/silent-failure-baseline.json
# and the gate fails when any strict metric *increases* against it.
#
# Complementary to scripts/ci/check-silent-failure-patterns.sh
# (binary anti-pattern detector, issue #9517). This ratchet is the
# *trend gate* — it permits the existing population but rejects net
# additions, so any new silent failure surfaces in PR review.
#
# Strict metrics (gated):
#   - error_to_ok_silence: `| Error _ -> Ok …` — promotes failure to
#     success silently. RFC-0088 §3 most-dangerous shape.
#   - error_result_silence: any `| Error _ -> (Ok|None|[]|true|false|())`.
#     Superset including the strict one.
#   - exception_catchall_swallow: `try … with _ -> …`. Absorbs every
#     exception including Eio.Cancel.Cancelled.
#
# Descriptive metric (printed only):
#   - variant_catchall_default: line-leading `| _ -> (None|[]|""|false
#     |true|()|Ok)`. Too broad to gate as strict (legitimate uses in
#     parser fallbacks dominate) but the trend is informative.
#
# Policy: ratchet only — current must be <= committed baseline. PRs
# that intentionally add a tracked shape (e.g. a refactor that
# justifies one site) must --regenerate AND document the rationale in
# the PR body, citing the new site. Silent baseline rebound after
# admin override is the anti-pattern (memory:
# feedback_ratchet-naturalization-after-admin-merge).
#
# Usage:
#   scripts/silent-failure-ratchet.sh             # check; exit 0 ok / 2 drift up / 1 error
#   scripts/silent-failure-ratchet.sh --regenerate # rewrite baseline from current counts
#   scripts/silent-failure-ratchet.sh --print     # print current counts, no compare

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BASELINE_FILE="${REPO_ROOT}/scripts/silent-failure-baseline.json"

for tool in rg python3 awk; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[silent-failure-ratchet] required tool missing: $tool" >&2
    exit 1
  }
done

# Scope: lib/ OCaml sources, excluding any test directories nested under lib/.
RG_SCOPE=(
  --type ocaml
  --glob 'lib/**/*.ml'
  --glob '!lib/**/test/**'
)

count_error_to_ok_silence() {
  ( set +o pipefail
    cd "$REPO_ROOT"
    rg -c '\|\s*Error\s+_\s*->\s*Ok' "${RG_SCOPE[@]}" 2>/dev/null \
      | awk -F: '{s+=$NF} END {print s+0}'
  )
}

count_error_result_silence() {
  ( set +o pipefail
    cd "$REPO_ROOT"
    rg -c '\|\s*Error\s+_\s*->\s*(Ok|None|\[\]|true|false|\(\))' "${RG_SCOPE[@]}" 2>/dev/null \
      | awk -F: '{s+=$NF} END {print s+0}'
  )
}

count_exception_catchall_swallow() {
  ( set +o pipefail
    cd "$REPO_ROOT"
    rg -c '\btry\b[^|]*\bwith\s+_\s*->' "${RG_SCOPE[@]}" 2>/dev/null \
      | awk -F: '{s+=$NF} END {print s+0}'
  )
}

count_variant_catchall_default() {
  ( set +o pipefail
    cd "$REPO_ROOT"
    rg -c '^\s*\|\s*_\s*->\s*(None|\[\]|""|false|true|\(\)|Ok)' "${RG_SCOPE[@]}" 2>/dev/null \
      | awk -F: '{s+=$NF} END {print s+0}'
  )
}

# Strict metrics — name|hint. The hint MUST NOT contain `|`; the
# parser splits on the LAST `|`, so a literal pipe in the hint would
# truncate the metric name. Describe variant shapes in prose instead.
METRICS=(
  "error_to_ok_silence|Error arm collapsed into Ok promotes failure to success silently. Propagate the error or wrap in a typed envelope."
  "error_result_silence|Error arm collapsed into a constant default Ok/None/empty-list/true/false/unit. Propagate the error or extract via a guarded helper."
  "exception_catchall_swallow|try with underscore catches every exception including Eio.Cancel.Cancelled. Match concrete exception constructors instead."
)

DESCRIPTIVE_METRICS=(
  "variant_catchall_default|Line-leading wildcard arm returning a default constant. Trend only — too broad to gate."
)

current_value() {
  case "$1" in
    error_to_ok_silence)         count_error_to_ok_silence ;;
    error_result_silence)        count_error_result_silence ;;
    exception_catchall_swallow)  count_exception_catchall_swallow ;;
    variant_catchall_default)    count_variant_catchall_default ;;
    *) echo "unknown metric: $1" >&2; exit 1 ;;
  esac
}

baseline_value() {
  local name="$1"
  if [[ -f "$BASELINE_FILE" ]]; then
    python3 -c "
import json
with open('$BASELINE_FILE') as f:
    data = json.load(f)
print(data.get('$name', 0))
"
  else
    echo 0
  fi
}

print_counts() {
  printf "%-32s %9s  %9s\n" "metric" "current" "baseline"
  echo "----------------------------------------------------------------"
  echo "[strict — ratchet enforced]"
  for spec in "${METRICS[@]}"; do
    local name="${spec%%|*}"
    local current baseline
    current=$(current_value "$name")
    baseline=$(baseline_value "$name")
    printf "%-32s %9d  %9d\n" "$name" "$current" "$baseline"
  done
  echo
  echo "[descriptive — recorded only]"
  for spec in "${DESCRIPTIVE_METRICS[@]}"; do
    local name="${spec%%|*}"
    local current baseline
    current=$(current_value "$name")
    baseline=$(baseline_value "$name")
    printf "%-32s %9d  %9d\n" "$name" "$current" "$baseline"
  done
}

regenerate() {
  local v_eto v_err v_exc v_var
  v_eto=$(count_error_to_ok_silence)
  v_err=$(count_error_result_silence)
  v_exc=$(count_exception_catchall_swallow)
  v_var=$(count_variant_catchall_default)
  python3 - "$BASELINE_FILE" "$v_eto" "$v_err" "$v_exc" "$v_var" <<'PYEOF'
import json, sys
path, eto, err, exc, var = sys.argv[1], *map(int, sys.argv[2:])
data = {
    "_comment": "Silent-failure ratchet baseline. Regenerate with scripts/silent-failure-ratchet.sh --regenerate.",
    "_metrics": "See scripts/silent-failure-ratchet.sh METRICS / DESCRIPTIVE_METRICS arrays.",
    "_audit": "lib/ silent failure code-smell audit 2026-05-20",
    "error_to_ok_silence":        eto,
    "error_result_silence":       err,
    "exception_catchall_swallow": exc,
    "variant_catchall_default":   var,
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(f"[regenerate] wrote {path}")
PYEOF
}

check() {
  local drift=0
  for spec in "${METRICS[@]}"; do
    local name="${spec%%|*}"
    local hint="${spec##*|}"
    local current baseline
    current=$(current_value "$name")
    baseline=$(baseline_value "$name")
    if (( current > baseline )); then
      echo "[silent-failure-ratchet] DRIFT UP: $name current=$current baseline=$baseline" >&2
      echo "  hint: $hint" >&2
      drift=1
    fi
  done
  return $drift
}

case "${1:-}" in
  --print)
    print_counts
    ;;
  --regenerate)
    regenerate
    ;;
  "")
    print_counts
    if check; then
      echo
      echo "[silent-failure-ratchet] OK"
      exit 0
    else
      echo
      echo "[silent-failure-ratchet] FAIL — current exceeds baseline" >&2
      echo "  if the increase is intentional, run --regenerate AND" >&2
      echo "  document the new site(s) in the PR body." >&2
      exit 2
    fi
    ;;
  *)
    echo "usage: $0 [--print | --regenerate]" >&2
    exit 1
    ;;
esac
