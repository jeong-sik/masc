#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${HITL_EXACT_BOUNDARY_ROOT:-$SOURCE_ROOT}"
WORKER="$ROOT/lib/keeper/hitl_summary_worker.ml"
GATE="$ROOT/lib/keeper/keeper_gate.ml"

fail() {
  printf 'HITL exact-flow boundary violation: %s\n' "$1" >&2
  exit 1
}

command -v rg >/dev/null 2>&1 || fail "ripgrep is required"

require_pattern() {
  local pattern="$1"
  local path="$2"
  local detail="$3"
  rg -q --multiline "$pattern" "$path" || fail "$detail"
}

forbid_pattern() {
  local pattern="$1"
  local path="$2"
  local detail="$3"
  if rg -q --multiline "$pattern" "$path"; then
    fail "$detail"
  fi
}

check_boundary() {
  require_pattern \
    'Exact_output\.admit_flow' \
    "$WORKER" \
    "worker must admit one immutable OAS flow"
  require_pattern \
    'Exact_output\.start_flow' \
    "$WORKER" \
    "worker must allocate only an OAS flow attempt"
  require_pattern \
    'Exact_output\.execute_flow_once' \
    "$WORKER" \
    "worker must execute only the affine OAS flow"
  require_pattern \
    'bind_summary_exact_attempt' \
    "$WORKER" \
    "before_dispatch must bind the real OAS receipt"
  require_pattern \
    'release_summary_exact_attempt_before_dispatch' \
    "$WORKER" \
    "before_advance must durably release the failed receipt"
  require_pattern \
    'quarantine_summary_exact_attempt' \
    "$WORKER" \
    "terminal failures must quarantine the exact receipt"
  require_pattern \
    'complete_summary_exact_attempt' \
    "$WORKER" \
    "success must atomically complete the exact receipt and summary"

  forbid_pattern \
    'Keeper_provider_subcall|Llm_provider|Provider_config|provider_config|Runtime\.hitl_summary_runtime_id|summary_mode|Native_structured|Plain_json_text' \
    "$WORKER" \
    "worker must not regain provider/config/sampling/degradation policy"
  forbid_pattern \
    'Exact_output\.(admit|start_attempt|execute_once)([^_[:alnum:]]|$)' \
    "$WORKER" \
    "worker must not reconstruct a candidate loop from legacy one-shot APIs"
  forbid_pattern \
    'Pricing|pricing|price|Limit|limit' \
    "$WORKER" \
    "pricing and limit observations are not HITL execution policy"
  forbid_pattern \
    'provider_config_for_summary|runtime_id:selected|set_runtime_hitl_summary' \
    "$GATE" \
    "Gate must remain provider/runtime blind"

  if rg -q \
    'hitl_summary_runtime_id|set_runtime_hitl_summary|Runtime_hitl_summary' \
    "$ROOT/lib" "$ROOT/dashboard/src" "$ROOT/test"; then
    fail "the retired HITL runtime scalar/API/UI surface was reintroduced"
  fi
  if rg -q \
    '^[[:space:]]*hitl_summary[[:space:]]*=' \
    "$ROOT/config"; then
    fail "runtime.toml must use the opaque hitl_auto_judge exact-output lane"
  fi

  printf 'HITL exact-flow boundary: OK\n'
}

self_test() (
  local fixture
  fixture="$(mktemp -d "${TMPDIR:-/tmp}/hitl-exact-boundary.XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  mkdir -p \
    "$fixture/lib/keeper" \
    "$fixture/dashboard/src" \
    "$fixture/config" \
    "$fixture/test"
  cp "$WORKER" "$fixture/lib/keeper/hitl_summary_worker.ml"
  cp "$GATE" "$fixture/lib/keeper/keeper_gate.ml"

  HITL_EXACT_BOUNDARY_ROOT="$fixture" "$0" --check >/dev/null

  printf '\nlet _ = Keeper_provider_subcall.complete\n' \
    >>"$fixture/lib/keeper/hitl_summary_worker.ml"
  if HITL_EXACT_BOUNDARY_ROOT="$fixture" "$0" --check >/dev/null 2>&1; then
    fail "self-test did not reject a direct provider subcall"
  fi
  cp "$WORKER" "$fixture/lib/keeper/hitl_summary_worker.ml"

  printf 'let hitl_summary_runtime_id = None\n' \
    >"$fixture/lib/retired_scalar.ml"
  if HITL_EXACT_BOUNDARY_ROOT="$fixture" "$0" --check >/dev/null 2>&1; then
    fail "self-test did not reject the retired runtime scalar"
  fi

  printf 'HITL exact-flow boundary self-test: OK\n'
)

case "${1:---check}" in
  --check) check_boundary ;;
  --self-test) self_test ;;
  *) fail "usage: $0 [--check|--self-test]" ;;
esac
