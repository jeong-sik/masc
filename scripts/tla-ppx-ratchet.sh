#!/usr/bin/env bash
# TLA+ PPX adoption ratchet gate.
#
# Tracks two strict metrics and one descriptive metric capturing
# runtime PPX adoption against the 84-spec TLA+ surface, documented
# in:
#   docs/audit/TLA-PPX-ADOPTION-AUDIT-2026-04.md
#
# Strict metrics (gate fails on DECREASE — we want monotonic
# increase):
#
#   - ppx_deriving_tla_modules: count of unique lib/ modules using
#     [@@deriving tla] (counted per .ml file; the .mli decl alone
#     is not enough — the ml is what generates the runtime helpers).
#     Floor: 4 (current) per Cycle 14 audit §2.1.
#
#   - ppx_fsm_guard_files: count of lib/ files with at least one
#     [@@fsm_guard] attribute. Floor: 3 (current) per §2.2.
#
# Descriptive metric (printed only, NOT gated):
#
#   - domains_with_zero_ppx_link: count of TLA spec domains where no
#     OCaml lib/ module is hooked via either PPX. Floor not enforced
#     because some domains are intentionally protocol-only (boundary
#     cross-domain specs — see boundary spot-check sister doc) and
#     should not be expected to gain a [@@deriving tla] hook.
#
# Inversion vs OAS ratchet:
#   The OAS boundary ratchet enforces an *upper* floor (current must
#   be ≤ baseline) because we want fewer direct violations. Here we
#   enforce a *lower* floor (current must be ≥ baseline) because we
#   want monotonic adoption growth.
#
# Policy: PRs that intentionally remove a [@@deriving tla] (e.g. when
# inlining a small variant) must --regenerate AND open a paired
# follow-up issue documenting the removal rationale. Anti-pattern:
# silent baseline drop after admin override.
#   (memory: feedback_ratchet-naturalization-after-admin-merge)
#
# Usage:
#   scripts/tla-ppx-ratchet.sh              # check; exit 0 ok / 2 drift down / 1 error
#   scripts/tla-ppx-ratchet.sh --regenerate # rewrite baseline from current counts
#   scripts/tla-ppx-ratchet.sh --print      # print current counts, no compare

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BASELINE_FILE="${REPO_ROOT}/scripts/tla-ppx-baseline.json"

# Required tools — fail fast (memory:
# feedback_ci_runner_dep_regression_silent_127).
for tool in rg python3 wc tr awk; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[tla-ppx-ratchet] required tool missing: $tool" >&2
    exit 1
  }
done

count_deriving_tla_modules() {
  # Count unique .ml files (not .mli) — the implementation is what
  # produces the generated runtime helpers; .mli is signature only.
  ( set +o pipefail
    cd "$REPO_ROOT"
    rg -l '\[@@deriving tla\]' lib/ --glob '*.ml' --glob '!*.mli' 2>/dev/null | wc -l | tr -d ' '
  )
}

count_fsm_guard_files() {
  ( set +o pipefail
    cd "$REPO_ROOT"
    rg -l '\[@@fsm_guard' lib/ --glob '*.ml' 2>/dev/null | wc -l | tr -d ' '
  )
}

count_lib_subdirs_with_ppx() {
  # Count distinct lib/ subdirectories containing at least one .ml
  # with [@@deriving tla] or [@@fsm_guard]. Higher is better.
  #
  # Why subdirs not files: a single subdir (e.g. lib/keeper) may
  # cluster many PPX files; counting subdirs gives a flat-domain
  # view of how many runtime areas have ANY TLA PPX hook.
  ( set +o pipefail
    cd "$REPO_ROOT"
    rg -l '\[@@deriving tla\]|\[@@fsm_guard' lib/ --glob '*.ml' 2>/dev/null \
      | awk -F/ '{print $1"/"$2}' \
      | sort -u \
      | wc -l \
      | tr -d ' '
  )
}

# Strict metrics: name|current_fn|hint
STRICT_METRICS=(
  "ppx_deriving_tla_modules|count_deriving_tla_modules|Modules using [@@deriving tla]. Decrease means a derived ADT was hand-written or inlined — open a follow-up issue."
  "ppx_fsm_guard_files|count_fsm_guard_files|Files with [@@fsm_guard]. Decrease means runtime invariant coverage shrank — explain in the PR."
)

DESCRIPTIVE_METRICS=(
  "lib_subdirs_with_ppx|count_lib_subdirs_with_ppx|Distinct lib/ subdirectories with at least one TLA PPX attribute. Higher is better but not enforced (cross-domain spread, not depth)."
)

current_value() {
  local fn="$1"
  $fn
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
  echo "[strict — ratchet enforced (monotonic increase)]"
  for spec in "${STRICT_METRICS[@]}"; do
    local name="${spec%%|*}"
    local rest="${spec#*|}"
    local fn="${rest%%|*}"
    local current baseline
    current=$(current_value "$fn")
    baseline=$(baseline_value "$name")
    printf "%-40s %9d  %9d\n" "$name" "$current" "$baseline"
  done
  echo
  echo "[descriptive — recorded only]"
  for spec in "${DESCRIPTIVE_METRICS[@]}"; do
    local name="${spec%%|*}"
    local rest="${spec#*|}"
    local fn="${rest%%|*}"
    local current baseline
    current=$(current_value "$fn")
    baseline=$(baseline_value "$name")
    printf "%-40s %9d  %9d\n" "$name" "$current" "$baseline"
  done
}

regenerate() {
  local d_modules f_files lib_subs
  d_modules=$(count_deriving_tla_modules)
  f_files=$(count_fsm_guard_files)
  lib_subs=$(count_lib_subdirs_with_ppx)
  python3 - "$BASELINE_FILE" "$d_modules" "$f_files" "$lib_subs" <<'PYEOF'
import json, sys
baseline_file, dm, ff, ls_ = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
data = {
    "_comment": "TLA+ PPX adoption baseline. Regenerate with scripts/tla-ppx-ratchet.sh --regenerate.",
    "_metrics": "See scripts/tla-ppx-ratchet.sh STRICT_METRICS / DESCRIPTIVE_METRICS arrays.",
    "_audit": "docs/audit/TLA-PPX-ADOPTION-AUDIT-2026-04.md",
    "ppx_deriving_tla_modules": dm,
    "ppx_fsm_guard_files":      ff,
    "lib_subdirs_with_ppx":     ls_,
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
    local hint="${spec##*|}"
    local current baseline
    current=$(current_value "$fn")
    baseline=$(baseline_value "$name")
    # Note: monotonic INCREASE — fail if current < baseline
    if (( current < baseline )); then
      echo "[tla-ppx-ratchet] DRIFT DOWN: $name current=$current baseline=$baseline" >&2
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
      echo "[tla-ppx-ratchet] OK"
      exit 0
    else
      echo
      echo "[tla-ppx-ratchet] FAIL — current is below baseline" >&2
      echo "  if the decrease is intentional (e.g. ADT inlined), run --regenerate" >&2
      echo "  AND open a paired follow-up issue documenting the removal rationale." >&2
      exit 2
    fi
    ;;
  *)
    echo "Usage: $0 [--print|--regenerate]" >&2
    exit 1
    ;;
esac
