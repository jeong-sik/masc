#!/usr/bin/env bash
# TLA+ Bug Model coverage ratchet gate.
#
# Spec-side ratchet for the Q-P0-2 audit chain. Companion to
# scripts/tla-ppx-ratchet.sh (PR #12151) which tracks runtime PPX
# adoption.
#
# Documented in:
#   docs/audit/TLA-SPECS-GAP-AUDIT-2026-04.md            (Phase 1)
#   docs/audit/TLA-SPECS-GAP-AUDIT-2026-04-PHASE2.md     (Phase 2)
#   docs/audit/TLA-SPECS-GAP-AUDIT-2026-04-PHASE3.md     (Phase 3)
#   docs/audit/TLA-SPECS-GAP-AUDIT-2026-04-PHASE3-CLOSURE.md
#
# Strict metrics (gate fails on regression direction):
#
#   - bug_model_coverage_specs (monotonic INCREASE):
#     count of *-buggy.cfg files across specs/. Each represents a
#     spec with a working Bug Model pair (clean.cfg + buggy.cfg).
#     Floor: current count. Goal: monotonic increase as more
#     specs gain Bug Models.
#
#   - domains_without_bug_model (monotonic DECREASE):
#     count of specs/<domain> directories with at least one .tla
#     file but zero *-buggy.cfg companions. After Phase 3 closure
#     this is 0; the ratchet enforces that no new domain regresses
#     to zero coverage.
#
# Policy: PRs that intentionally drop a *-buggy.cfg (e.g. when a
# Bug Model is found incorrect and is being rewritten) must
# --regenerate AND open a paired follow-up issue documenting the
# removal rationale. Anti-pattern: silent baseline drop after
# admin override (memory:
# feedback_ratchet-naturalization-after-admin-merge).
#
# Usage:
#   scripts/tla-bug-model-ratchet.sh              # check; exit 0 ok / 2 drift / 1 error
#   scripts/tla-bug-model-ratchet.sh --regenerate # rewrite baseline from current counts
#   scripts/tla-bug-model-ratchet.sh --print      # print current counts, no compare

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BASELINE_FILE="${REPO_ROOT}/scripts/tla-bug-model-baseline.json"

# Required tools — fail fast (memory:
# feedback_ci_runner_dep_regression_silent_127).
for tool in find python3 wc tr; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[tla-bug-model-ratchet] required tool missing: $tool" >&2
    exit 1
  }
done

count_bug_model_specs() {
  ( set +o pipefail
    cd "$REPO_ROOT"
    find specs -name '*-buggy*.cfg' -not -path '*/states/*' 2>/dev/null \
      | wc -l | tr -d ' '
  )
}

count_domains_without_bug_model() {
  # For each specs/<domain>/, check whether it has at least one .tla
  # AND zero *-buggy*.cfg files.
  ( set +o pipefail
    cd "$REPO_ROOT"
    local zero=0
    for dir in specs/*/; do
      local domain
      domain=$(basename "$dir")
      # Skip artifact / non-spec directories
      case "$domain" in
        states) continue ;;
      esac
      local tla_count buggy_count
      tla_count=$(find "$dir" -maxdepth 2 -name '*.tla' -not -name '*TTrace*' 2>/dev/null | wc -l | tr -d ' ')
      buggy_count=$(find "$dir" -maxdepth 2 -name '*-buggy*.cfg' 2>/dev/null | wc -l | tr -d ' ')
      if (( tla_count > 0 )) && (( buggy_count == 0 )); then
        zero=$((zero + 1))
      fi
    done
    echo "$zero"
  )
}

# name|fn|hint|direction (INC=monotonic increase / DEC=monotonic decrease)
STRICT_METRICS=(
  "bug_model_coverage_specs|count_bug_model_specs|Specs with *-buggy.cfg companion. Decrease means a Bug Model was removed — open a follow-up issue.|INC"
  "domains_without_bug_model|count_domains_without_bug_model|Domains with .tla but zero *-buggy.cfg. Increase means a domain regressed to zero coverage.|DEC"
)

current_value() {
  $1
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
  printf "%-40s %9s  %9s  %4s\n" "metric" "current" "baseline" "dir"
  echo "----------------------------------------------------------------------"
  echo "[strict — ratchet enforced]"
  for spec in "${STRICT_METRICS[@]}"; do
    local name="${spec%%|*}"
    local rest="${spec#*|}"
    local fn="${rest%%|*}"
    local rest2="${rest#*|}"
    local _hint="${rest2%%|*}"
    local dir="${spec##*|}"
    local current baseline
    current=$(current_value "$fn")
    baseline=$(baseline_value "$name")
    printf "%-40s %9d  %9d  %4s\n" "$name" "$current" "$baseline" "$dir"
  done
}

regenerate() {
  local cov dom
  cov=$(count_bug_model_specs)
  dom=$(count_domains_without_bug_model)
  python3 - "$BASELINE_FILE" "$cov" "$dom" <<'PYEOF'
import json, sys
baseline_file, cov, dom = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
data = {
    "_comment": "TLA+ Bug Model coverage baseline. Regenerate with scripts/tla-bug-model-ratchet.sh --regenerate.",
    "_metrics": "See scripts/tla-bug-model-ratchet.sh STRICT_METRICS array.",
    "_audit": "docs/audit/TLA-SPECS-GAP-AUDIT-2026-04*.md",
    "bug_model_coverage_specs": cov,
    "domains_without_bug_model": dom,
}
with open(baseline_file, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(f"[regenerate] wrote {baseline_file}")
PYEOF
}

check() {
  local drift=0
  for spec in "${STRICT_METRICS[@]}"; do
    local name="${spec%%|*}"
    local rest="${spec#*|}"
    local fn="${rest%%|*}"
    local rest2="${rest#*|}"
    local hint="${rest2%%|*}"
    local dir="${spec##*|}"
    local current baseline
    current=$(current_value "$fn")
    baseline=$(baseline_value "$name")
    case "$dir" in
      INC)
        if (( current < baseline )); then
          echo "[tla-bug-model-ratchet] DRIFT DOWN: $name current=$current baseline=$baseline" >&2
          echo "  hint: $hint" >&2
          drift=1
        fi
        ;;
      DEC)
        if (( current > baseline )); then
          echo "[tla-bug-model-ratchet] DRIFT UP: $name current=$current baseline=$baseline" >&2
          echo "  hint: $hint" >&2
          drift=1
        fi
        ;;
    esac
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
      echo "[tla-bug-model-ratchet] OK"
      exit 0
    else
      echo
      echo "[tla-bug-model-ratchet] FAIL — current is on the wrong side of baseline" >&2
      echo "  if intentional, run --regenerate AND open a paired follow-up issue." >&2
      exit 2
    fi
    ;;
  *)
    echo "Usage: $0 [--print|--regenerate]" >&2
    exit 1
    ;;
esac
