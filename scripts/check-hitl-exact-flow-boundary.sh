#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${HITL_EXACT_BOUNDARY_ROOT:-$SOURCE_ROOT}"
WORKER="$ROOT/lib/keeper/hitl_summary_worker.ml"
GATE="$ROOT/lib/keeper/keeper_gate.ml"
RUNTIME_MLI="$ROOT/lib/runtime/runtime.mli"
BOOTSTRAP="$ROOT/lib/server/server_runtime_bootstrap.ml"
FLOW_TEST="$ROOT/test/test_hitl_summary_worker.ml"

fail() {
  printf 'HITL exact-flow boundary violation: %s\n' "$1" >&2
  exit 1
}

command -v rg >/dev/null 2>&1 || fail "ripgrep is required"

matches_pattern() {
  local pattern="$1"
  shift
  if rg -q --multiline -- "$pattern" "$@"; then
    return 0
  else
    local status=$?
    if [[ $status -eq 1 ]]; then
      return 1
    fi
    fail "rg failed while checking: $*"
  fi
}

require_pattern() {
  local pattern="$1"
  local path="$2"
  local detail="$3"
  matches_pattern "$pattern" "$path" || fail "$detail"
}

forbid_pattern() {
  local pattern="$1"
  local path="$2"
  local detail="$3"
  if matches_pattern "$pattern" "$path"; then
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
    '~before_dispatch:\(before_dispatch[[:space:]]+~queue_writers[[:space:]]+prepared\.entry\)' \
    "$WORKER" \
    "execute_flow_once must use the production durable bind callback"
  require_pattern \
    '~before_advance:\(before_advance[[:space:]]+~queue_writers[[:space:]]+prepared\.entry\)' \
    "$WORKER" \
    "execute_flow_once must use the production durable advance callback"
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
  require_pattern \
    'write_outcome = Fsync_completed' \
    "$WORKER" \
    "dispatch and Gate delivery must require confirmed durability"
  for accessor in \
    receipt_call_id \
    receipt_plan_fingerprint \
    receipt_request_body_sha256 \
    receipt_catalog_generation \
    receipt_catalog_evidence \
    receipt_target_identity; do
    require_pattern \
      "Exact_output\\.${accessor}" \
      "$WORKER" \
      "success provenance must retain ${accessor}"
  done
  require_pattern \
    'val publish_exact_output_registry' \
    "$RUNTIME_MLI" \
    "Runtime must expose the production immutable registry publication boundary"
  require_pattern \
    'Runtime\.publish_exact_output_registry' \
    "$BOOTSTRAP" \
    "server bootstrap must use the public Runtime publication boundary"
  require_pattern \
    'Runtime\.publish_exact_output_registry' \
    "$FLOW_TEST" \
    "flow tests must publish through the production Runtime boundary"

  forbid_pattern \
    'Keeper_provider_subcall|Llm_provider|Provider_config|provider_config|Runtime\.hitl_summary_runtime_id|summary_mode|Native_structured|Plain_json_text' \
    "$WORKER" \
    "worker must not regain provider/config/sampling/degradation policy"
  forbid_pattern \
    'Http_client|Cohttp|request_path|http_status|Retry\.|retry_policy|retry_after|is_retryable|Error_domain|Capabilities|capability_|supports_|validate_output_schema_request' \
    "$WORKER" \
    "worker must not bypass OAS HTTP, retry, or capability policy"
  forbid_pattern \
    'ready_flow_admissions|Candidate_admitted|Candidate_rejected|admission_error' \
    "$WORKER" \
    "MASC must not interpret OAS candidate admission causes"
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
  forbid_pattern \
    'Runtime_exact_output_registry' \
    "$FLOW_TEST" \
    "tests must not bypass the public Runtime registry boundary"

  if matches_pattern \
    'hitl_summary_runtime_id|set_runtime_hitl_summary|Runtime_hitl_summary' \
    "$ROOT/lib" "$ROOT/dashboard/src" "$ROOT/test"; then
    fail "the retired HITL runtime scalar/API/UI surface was reintroduced"
  fi
  if matches_pattern \
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
  mkdir -p "$fixture/lib/runtime" "$fixture/lib/server"
  cp "$RUNTIME_MLI" "$fixture/lib/runtime/runtime.mli"
  cp "$BOOTSTRAP" "$fixture/lib/server/server_runtime_bootstrap.ml"
  cp "$FLOW_TEST" "$fixture/test/test_hitl_summary_worker.ml"

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
  rm "$fixture/lib/retired_scalar.ml"

  mv \
    "$fixture/lib/keeper/hitl_summary_worker.ml" \
    "$fixture/lib/keeper/hitl_summary_worker.ml.missing"
  if HITL_EXACT_BOUNDARY_ROOT="$fixture" "$0" --check >/dev/null 2>&1; then
    fail "self-test accepted an unreadable required source"
  fi

  printf 'HITL exact-flow boundary self-test: OK\n'
)

case "${1:---check}" in
  --check) check_boundary ;;
  --self-test) self_test ;;
  *) fail "usage: $0 [--check|--self-test]" ;;
esac
