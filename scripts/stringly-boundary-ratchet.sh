#!/usr/bin/env bash
# Stringly typed OCaml boundary ratchet.
#
# Tracks the first #11926 exact-match sweep surfaces. The strict metrics are
# families that have already reached zero on main; they must stay zero. The
# descriptive metrics are the next broad families still under migration.
#
# Strict metrics:
#   - raw_decision_string_signatures: `decision : string` / `?decision:string`
#   - raw_error_kind_string_signatures: `error_kind : string` / `?error_kind:string`
#
# Descriptive metrics:
#   - raw_cascade_name_string_signatures
#   - raw_status_string_signatures
#
# Usage:
#   scripts/stringly-boundary-ratchet.sh              # check; exit 0 ok / 2 drift up / 1 error
#   scripts/stringly-boundary-ratchet.sh --regenerate # rewrite baseline from current counts
#   scripts/stringly-boundary-ratchet.sh --print      # print current counts, no compare

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BASELINE_FILE="${REPO_ROOT}/scripts/stringly-boundary-baseline.json"

for tool in rg python3 awk; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[stringly-boundary-ratchet] required tool missing: $tool" >&2
    exit 1
  }
done

count_field_string_signatures() {
  local field="$1"
  ( set +o pipefail
    cd "$REPO_ROOT"
    rg -c -e "[?]?${field}[[:space:]]*:[[:space:]]*string" \
      --glob "*.ml" --glob "*.mli" lib test 2>/dev/null \
      | awk -F: '{sum+=$NF} END {print sum+0}'
  )
}

# Metric definitions: name|field|hint
METRICS=(
  "raw_decision_string_signatures|decision|Raw decision:string signature reintroduced; use the local typed decision wrapper and render strings only at wire/log boundaries."
  "raw_error_kind_string_signatures|error_kind|Raw error_kind:string signature reintroduced; use the local typed error_kind wrapper and render strings only at wire/log boundaries."
)

DESCRIPTIVE_METRICS=(
  "raw_cascade_name_string_signatures|cascade_name|Remaining cascade_name:string signatures; descriptive while C-T7.2 continues."
  "raw_status_string_signatures|status|Remaining status:string signatures; descriptive until a scoped status sweep starts."
)

field_for_metric() {
  local name="$1"
  local spec metric field
  for spec in "${METRICS[@]}" "${DESCRIPTIVE_METRICS[@]}"; do
    metric="${spec%%|*}"
    if [[ "$metric" == "$name" ]]; then
      field="${spec#*|}"
      field="${field%%|*}"
      printf '%s\n' "$field"
      return 0
    fi
  done
  echo "unknown metric: $name" >&2
  exit 1
}

hint_for_metric() {
  local name="$1"
  local spec metric hint
  for spec in "${METRICS[@]}" "${DESCRIPTIVE_METRICS[@]}"; do
    metric="${spec%%|*}"
    if [[ "$metric" == "$name" ]]; then
      hint="${spec#*|}"
      hint="${hint#*|}"
      printf '%s\n' "$hint"
      return 0
    fi
  done
  echo "unknown metric: $name" >&2
  exit 1
}

current_value() {
  count_field_string_signatures "$(field_for_metric "$1")"
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

print_group() {
  local title="$1"
  shift
  echo "$title"
  local spec name current baseline
  for spec in "$@"; do
    name="${spec%%|*}"
    current=$(current_value "$name")
    baseline=$(baseline_value "$name")
    printf "%-38s %9d  %9d\n" "$name" "$current" "$baseline"
  done
}

print_counts() {
  printf "%-38s %9s  %9s\n" "metric" "current" "baseline"
  echo "------------------------------------------------------------"
  print_group "[strict - ratchet enforced]" "${METRICS[@]}"
  echo
  print_group "[descriptive - recorded only]" "${DESCRIPTIVE_METRICS[@]}"
}

regenerate() {
  local decision error_kind cascade_name status
  decision=$(current_value raw_decision_string_signatures)
  error_kind=$(current_value raw_error_kind_string_signatures)
  cascade_name=$(current_value raw_cascade_name_string_signatures)
  status=$(current_value raw_status_string_signatures)
  python3 - "$BASELINE_FILE" "$decision" "$error_kind" "$cascade_name" "$status" <<'PYEOF'
import json, sys
baseline_file = sys.argv[1]
decision, error_kind, cascade_name, status = map(int, sys.argv[2:])
data = {
    "_comment": "Stringly boundary baseline. Regenerate with scripts/stringly-boundary-ratchet.sh --regenerate.",
    "_metrics": "See scripts/stringly-boundary-ratchet.sh METRICS / DESCRIPTIVE_METRICS arrays.",
    "_issue": "#11926",
    "raw_decision_string_signatures": decision,
    "raw_error_kind_string_signatures": error_kind,
    "raw_cascade_name_string_signatures": cascade_name,
    "raw_status_string_signatures": status,
}
with open(baseline_file, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(f"[regenerate] wrote {baseline_file}")
PYEOF
}

check() {
  local drift=0
  local spec name current baseline hint
  for spec in "${METRICS[@]}"; do
    name="${spec%%|*}"
    current=$(current_value "$name")
    baseline=$(baseline_value "$name")
    if (( current > baseline )); then
      hint=$(hint_for_metric "$name")
      echo "[stringly-boundary-ratchet] DRIFT UP: $name current=$current baseline=$baseline" >&2
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
      echo "[stringly-boundary-ratchet] OK"
      exit 0
    else
      echo
      echo "[stringly-boundary-ratchet] FAIL - current exceeds baseline" >&2
      echo "  if the increase is intentional, run --regenerate AND open a" >&2
      echo "  paired follow-up issue documenting the boundary change." >&2
      exit 2
    fi
    ;;
  *)
    echo "Usage: $0 [--print|--regenerate]" >&2
    exit 1
    ;;
esac
