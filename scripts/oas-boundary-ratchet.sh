#!/usr/bin/env bash
# OAS↔MASC boundary ratchet gate.
#
# Tracks one strict metric and one descriptive metric capturing the
# OAS adapter boundary discipline documented in:
#   docs/audit/OAS-MASC-BOUNDARY-AUDIT-2026-04.md         (Phase 1)
#   docs/audit/OAS-MASC-BOUNDARY-AUDIT-2026-04-PHASE2.md  (Phase 2)
#
# Strict metric (gate fails on increase, baseline 0):
#   - c4_direct_runtime_calls_layer_c: count of side-effecting OAS
#     runtime invocations (Oas.Agent.run, Oas.Tool.dispatch) in
#     Layer C — lib/keeper/, lib/server/, lib/dashboard/, lib/local/
#     EXCLUDING the lib/oas_*.ml adapter family and lib/keeper/
#     keeper_*oas*.ml hook factories (those are Layer B).
#
#     The Phase 2 inspection found this count is currently 0; every
#     such call routes through Masc_oas_bridge / Keeper_tools_oas /
#     Oas_worker. The floor enforces that discipline going forward.
#     Phase 2 §6 records the rationale.
#
# Descriptive metric (printed only, NOT gated):
#   - bridge_adoption_files: count of Layer C files importing
#     Masc_oas_bridge directly. Higher is better but not enforced
#     because some Layer C → Layer B paths legitimately go through
#     other adapters (Keeper_tools_oas, Oas_worker, etc.). Recording
#     the trend lets future contributors detect silent regressions.
#
# Policy: ratchet only — c4 metric current value must be <= committed
# baseline. PRs that *intentionally* loosen the discipline (e.g. a
# refactor that justifies a direct call) must --regenerate AND open a
# paired follow-up issue. Anti-pattern: silent baseline rebound after
# admin override (memory: feedback_ratchet-naturalization-after-admin-merge).
#
# Usage:
#   scripts/oas-boundary-ratchet.sh              # check; exit 0 ok / 2 drift up / 1 error
#   scripts/oas-boundary-ratchet.sh --regenerate # rewrite baseline from current counts
#   scripts/oas-boundary-ratchet.sh --print      # print current counts, no compare
#   scripts/oas-boundary-ratchet.sh --self-test  # prove clean/pass and reintroduction/fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BASELINE_FILE="${REPO_ROOT}/scripts/oas-boundary-baseline.json"

# Required tools — fail fast with an actionable message rather than
# the silent exit-127 that bites a pipefail-protected `rg | wc | tr`
# when ripgrep is absent (memory: feedback_ci_runner_dep_regression_silent_127).
for tool in rg python3 wc tr; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[oas-boundary-ratchet] required tool missing: $tool" >&2
    exit 1
  }
done

# Layer C scope: lib/keeper, lib/server, lib/dashboard, lib/local.
# EXCLUDE the Layer B adapter family. Excluding via `--glob` keeps
# the rg invocation honest and the exclusion list visible at the
# call site, not buried in shell logic.
LAYER_C_GLOBS=(
  --glob 'lib/keeper/**/*.ml'
  --glob 'lib/server/**/*.ml'
  --glob 'lib/dashboard/**/*.ml'
  --glob 'lib/local/**/*.ml'
  # Exclude Layer B adapter modules — these MAY call Oas.Agent.run.
  --glob '!lib/oas_*.ml'
  --glob '!lib/keeper/keeper_*oas*.ml'
  --glob '!lib/dashboard/dashboard_oas_*.ml'
)

count_c4_direct_calls() {
  # rg exits 1 on zero matches. set +o pipefail in subshell to keep
  # the rest of the script under strict pipeline behavior. -c prints
  # per-file counts; sum them with awk. Empty output → 0.
  ( set +o pipefail
    cd "$REPO_ROOT"
    rg -c 'Oas\.Agent\.run|Oas\.Tool\.dispatch' "${LAYER_C_GLOBS[@]}" 2>/dev/null \
      | awk -F: '{sum+=$NF} END {print sum+0}'
  )
}

count_bridge_adoption() {
  ( set +o pipefail
    cd "$REPO_ROOT"
    rg -l 'Masc_oas_bridge\.' "${LAYER_C_GLOBS[@]}" 2>/dev/null | wc -l | tr -d ' '
  )
}

count_retired_bridge_timeout_policy() {
  local retired_names bridge_timeout_args
  retired_names=$(
    ( set +o pipefail
      cd "$REPO_ROOT"
      rg -n 'Env_config_oas_bridge|run_with_caller|MASC_OAS_BRIDGE_TIMEOUT_' \
        lib --glob '*.ml' --glob '*.mli' 2>/dev/null | wc -l | tr -d ' '
    )
  )
  bridge_timeout_args=$(
    ( set +o pipefail
      cd "$REPO_ROOT"
      rg -n 'timeout_s' lib/masc_oas_bridge.ml lib/masc_oas_bridge.mli \
        2>/dev/null | wc -l | tr -d ' '
    )
  )
  echo $((retired_names + bridge_timeout_args))
}

# Metric definitions: name|hint
METRICS=(
  "c4_direct_runtime_calls_layer_c|Direct Oas.Agent.run / Oas.Tool.dispatch in Layer C — route through Masc_oas_bridge.run_safe (or Keeper_tools_oas / Oas_worker)."
  "retired_bridge_timeout_policy|Bridge timeout config/API was deleted; do not restore Env_config_oas_bridge, run_with_caller, timeout_s on Masc_oas_bridge, or MASC_OAS_BRIDGE_TIMEOUT_* env vars."
)

DESCRIPTIVE_METRICS=(
  "bridge_adoption_files|Layer C files importing Masc_oas_bridge — descriptive only."
)

current_value() {
  case "$1" in
    c4_direct_runtime_calls_layer_c) count_c4_direct_calls ;;
    retired_bridge_timeout_policy)   count_retired_bridge_timeout_policy ;;
    bridge_adoption_files)           count_bridge_adoption ;;
    *) echo "unknown metric: $1" >&2; exit 1 ;;
  esac
}

baseline_value() {
  local name="$1"
  if [[ -f "$BASELINE_FILE" ]]; then
    python3 -c "
import json, sys
with open('$BASELINE_FILE') as f:
    data = json.load(f)
print(data.get('$name', 0))
"
  else
    echo 0
  fi
}

print_counts() {
  printf "%-40s %9s  %9s\n" "metric" "current" "baseline"
  echo "----------------------------------------------------------------"
  echo "[strict — ratchet enforced]"
  for spec in "${METRICS[@]}"; do
    local name="${spec%%|*}"
    local current baseline
    current=$(current_value "$name")
    baseline=$(baseline_value "$name")
    printf "%-40s %9d  %9d\n" "$name" "$current" "$baseline"
  done
  echo
  echo "[descriptive — recorded only]"
  for spec in "${DESCRIPTIVE_METRICS[@]}"; do
    local name="${spec%%|*}"
    local current baseline
    current=$(current_value "$name")
    baseline=$(baseline_value "$name")
    printf "%-40s %9d  %9d\n" "$name" "$current" "$baseline"
  done
}

regenerate() {
  local c4 retired_timeout bridge
  c4=$(count_c4_direct_calls)
  retired_timeout=$(count_retired_bridge_timeout_policy)
  bridge=$(count_bridge_adoption)
  python3 - "$BASELINE_FILE" "$c4" "$retired_timeout" "$bridge" <<'PYEOF'
import json, sys
baseline_file = sys.argv[1]
c4, retired_timeout, bridge = map(int, sys.argv[2:])
data = {
    "_comment": "OAS<->MASC boundary baseline. Regenerate with scripts/oas-boundary-ratchet.sh --regenerate.",
    "_metrics": "See scripts/oas-boundary-ratchet.sh METRICS / DESCRIPTIVE_METRICS arrays.",
    "_audit": "docs/audit/OAS-MASC-BOUNDARY-AUDIT-2026-04*.md",
    "c4_direct_runtime_calls_layer_c": c4,
    "retired_bridge_timeout_policy":   retired_timeout,
    "bridge_adoption_files":           bridge,
}
with open(baseline_file, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(f"[regenerate] wrote {baseline_file}")
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
      echo "[oas-boundary-ratchet] DRIFT UP: $name current=$current baseline=$baseline" >&2
      echo "  hint: $hint" >&2
      drift=1
    fi
  done
  return $drift
}

self_test() (
  local fixture clean_count drift_count
  fixture=$(mktemp -d "${TMPDIR:-/tmp}/oas-boundary-ratchet.XXXXXX")
  trap 'rm -rf "$fixture"' EXIT
  mkdir -p \
    "$fixture/lib/keeper" \
    "$fixture/lib/server" \
    "$fixture/lib/dashboard" \
    "$fixture/lib/local" \
    "$fixture/scripts"
  : >"$fixture/lib/masc_oas_bridge.ml"
  : >"$fixture/lib/masc_oas_bridge.mli"
  printf '%s\n' \
    '{"c4_direct_runtime_calls_layer_c":0,"retired_bridge_timeout_policy":0}' \
    >"$fixture/scripts/oas-boundary-baseline.json"

  REPO_ROOT="$fixture"
  BASELINE_FILE="$fixture/scripts/oas-boundary-baseline.json"

  clean_count=$(count_retired_bridge_timeout_policy)
  if [[ "$clean_count" != "0" ]] || ! check >/dev/null 2>&1; then
    echo "[oas-boundary-ratchet:self-test] clean fixture did not pass (count=$clean_count)" >&2
    exit 1
  fi
  echo "[oas-boundary-ratchet:self-test] clean fixture: count=0 check=pass"

  printf '%s\n' \
    'let _ = Env_config_oas_bridge.operator_judge_timeout_s ()' \
    >"$fixture/lib/retired_bridge_timeout_policy.ml"
  drift_count=$(count_retired_bridge_timeout_policy)
  if [[ "$drift_count" == "0" ]] || check >/dev/null 2>&1; then
    echo "[oas-boundary-ratchet:self-test] forbidden fixture did not fail (count=$drift_count)" >&2
    exit 1
  fi
  echo "[oas-boundary-ratchet:self-test] forbidden fixture: count=$drift_count check=fail"
)

case "${1:-}" in
  --print)
    print_counts
    ;;
  --regenerate)
    regenerate
    ;;
  --self-test)
    self_test
    ;;
  "")
    print_counts
    if check; then
      echo
      echo "[oas-boundary-ratchet] OK"
      exit 0
    else
      echo
      echo "[oas-boundary-ratchet] FAIL — current exceeds baseline" >&2
      echo "  if the increase is intentional, run --regenerate AND open a" >&2
      echo "  paired follow-up issue documenting the discipline change." >&2
      exit 2
    fi
    ;;
  *)
    echo "Usage: $0 [--print|--regenerate|--self-test]" >&2
    exit 1
    ;;
esac
