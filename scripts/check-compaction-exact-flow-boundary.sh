#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MASC_COMPACTION_BOUNDARY_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
TARGET="${MASC_COMPACTION_EXACT_FLOW_TARGET:-${REPO_ROOT}/lib/keeper/keeper_compaction_llm_summarizer.ml}"

fail() {
  echo "[compaction-exact-flow-boundary] $*" >&2
  exit 1
}

count_fixed() {
  local token="$1"
  { rg -o --fixed-strings "${token}" "${TARGET}" 2>/dev/null || true; } \
    | wc -l \
    | tr -d ' '
}

require_once() {
  local token="$1"
  local count
  count="$(count_fixed "${token}")"
  [[ "${count}" == "1" ]] \
    || fail "expected exactly one ${token} call in ${TARGET}, found ${count}"
}

check_boundary() {
  [[ -f "${TARGET}" ]] || fail "target not found: ${TARGET}"
  [[ ! -e "${REPO_ROOT}/lib/keeper/keeper_compaction_projection_target.ml" ]] \
    || fail "retired compaction provider/model projection carrier remains"
  [[ ! -e "${REPO_ROOT}/lib/keeper/keeper_compaction_projection_target.mli" ]] \
    || fail "retired compaction provider/model projection interface remains"

  require_once "Exact_output.make_flow_candidate"
  require_once "Exact_output.snapshot_flow"
  require_once "Exact_output.start_flow"
  require_once "Exact_output.execute_flow_once"
  require_once "Exact_output.settle_flow_domain"

  local forbidden_pattern
  forbidden_pattern='Exact_output\.admit_flow|Exact_output\.admit([^_[:alnum:]]|$)|Exact_output\.(start_attempt|execute_once|receipt_phase|receipt_dispatch_count)|Exact_output\.effect_phase|type admitted_slot|is_before_dispatch_zero|ready_plan'
  if rg -n "${forbidden_pattern}" "${TARGET}"; then
    fail "MASC-local exact admission/attempt/receipt control flow is forbidden"
  fi

  local projection_pattern
  local projection_candidates
  local projection_targets=()
  projection_pattern='Keeper_compaction_projection_target|projection_(request|target|provider|model)|((provider|model)_projection)|Llm_provider\.Provider_config|provider_config|provider_id|model_id|oas_provider_kind'
  projection_candidates=(
    "${TARGET}"
    "${REPO_ROOT}/lib/keeper/keeper_post_turn.ml"
    "${REPO_ROOT}/lib/keeper/keeper_post_turn.mli"
    "${REPO_ROOT}/lib/keeper/keeper_context_runtime.ml"
    "${REPO_ROOT}/lib/keeper/keeper_context_runtime.mli"
    "${REPO_ROOT}/lib/keeper/keeper_manual_compaction.ml"
    "${REPO_ROOT}/lib/keeper/keeper_unified_turn.ml"
  )
  for candidate in "${projection_candidates[@]}"; do
    [[ -f "${candidate}" ]] && projection_targets+=("${candidate}")
  done
  if rg -n "${projection_pattern}" "${projection_targets[@]}"; then
    fail "MASC compaction path must not project provider/model identity"
  fi

  local failed_after="Execution_failed_"'after_dispatch'
  local failed_before="Exact_execution_failed_"'before_dispatch'
  local cancelled_after="Execution_cancelled_"'after_dispatch'
  local lower_failed_after="execution_failed_"'after_dispatch'
  local lower_failed_before="exact_execution_failed_"'before_dispatch'
  local lower_cancelled_after="execution_cancelled_"'after_dispatch'
  local attempt_constructor="Attempt_already_"'started'
  local exact_attempt_constructor="Exact_attempt_already_"'started'
  local provenance_constructor="Execution_provenance_"'mismatch'
  local exact_provenance_constructor="Exact_execution_provenance_"'mismatch'
  local provenance_label="execution_provenance_"'mismatch'
  local attempt_label="attempt_already_"'started'
  local old_pattern
  local legacy_label_candidates
  local legacy_label_targets=()
  old_pattern="${failed_after}|${failed_before}|${cancelled_after}|${lower_failed_after}|${lower_failed_before}|${lower_cancelled_after}|${attempt_constructor}|${exact_attempt_constructor}|${provenance_constructor}|${exact_provenance_constructor}|\"${provenance_label}\"|\"${attempt_label}\""
  legacy_label_candidates=(
    "${TARGET}"
    "${REPO_ROOT}/lib/keeper/keeper_compaction_llm_summarizer.mli"
    "${REPO_ROOT}/lib/keeper/keeper_registry_event_queue_exact_execution.ml"
    "${REPO_ROOT}/lib/keeper/keeper_registry_event_queue_exact_execution.mli"
    "${REPO_ROOT}/lib/keeper_runtime/keeper_event_queue_persistence.ml"
    "${REPO_ROOT}/lib/keeper_runtime/keeper_event_queue_persistence.mli"
    "${REPO_ROOT}/lib/keeper_runtime/keeper_event_queue_state.ml"
    "${REPO_ROOT}/lib/keeper_runtime/keeper_event_queue_state.mli"
    "${REPO_ROOT}/test/test_compaction_exact_output_conformance.ml"
    "${REPO_ROOT}/test/test_keeper_event_queue_state_v2.ml"
    "${REPO_ROOT}/test/test_keeper_exact_execution_lease_guard.ml"
  )
  for candidate in "${legacy_label_candidates[@]}"; do
    [[ -f "${candidate}" ]] && legacy_label_targets+=("${candidate}")
  done
  if rg -n "${old_pattern}" "${legacy_label_targets[@]}"; then
    fail "retired receipt-phase or legacy durable terminal label remains"
  fi

  echo "[compaction-exact-flow-boundary] OK"
}

self_test() {
  local fixture target clean adjacent adjacent_clean
  fixture="$(mktemp -d "${TMPDIR:-/tmp}/compaction-exact-flow-boundary.XXXXXX")"
  trap "rm -rf '${fixture}'" EXIT
  mkdir -p "${fixture}/lib/keeper" "${fixture}/test"
  target="${fixture}/lib/keeper/keeper_compaction_llm_summarizer.ml"
  adjacent="${fixture}/lib/keeper/keeper_post_turn.ml"
  cat >"${target}" <<'EOF'
let _ = Exact_output.make_flow_candidate
let _ = Exact_output.snapshot_flow
let _ = Exact_output.start_flow
let _ = Exact_output.execute_flow_once
let _ = Exact_output.settle_flow_domain
EOF
  printf '%s\n' 'let _ = ()' >"${adjacent}"
  clean="${fixture}/compaction.ml.clean"
  adjacent_clean="${fixture}/post-turn.ml.clean"
  cp "${target}" "${clean}"
  cp "${adjacent}" "${adjacent_clean}"
  printf '%s\n' \
    'let _ = Exact_attempt_already_started' \
    >"${fixture}/lib/keeper/keeper_librarian_runtime.ml"

  MASC_COMPACTION_BOUNDARY_ROOT="${fixture}" \
    MASC_COMPACTION_EXACT_FLOW_TARGET="${target}" \
    "${BASH_SOURCE[0]}" --check-only >/dev/null

  printf '%s\n' 'let _ = Exact_output.snapshot_flow' >>"${target}"
  if
    MASC_COMPACTION_BOUNDARY_ROOT="${fixture}" \
      MASC_COMPACTION_EXACT_FLOW_TARGET="${target}" \
      "${BASH_SOURCE[0]}" --check-only >/dev/null 2>&1
  then
    fail "self-test duplicate canonical snapshot unexpectedly passed"
  fi
  cp "${clean}" "${target}"

  python3 - "${target}" <<'PY'
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
source = target.read_text()
target.write_text(source.replace("let _ = Exact_output.snapshot_flow\n", "", 1))
PY
  if
    MASC_COMPACTION_BOUNDARY_ROOT="${fixture}" \
      MASC_COMPACTION_EXACT_FLOW_TARGET="${target}" \
      "${BASH_SOURCE[0]}" --check-only >/dev/null 2>&1
  then
    fail "self-test missing canonical snapshot unexpectedly passed"
  fi
  cp "${clean}" "${target}"

  printf '%s\n' 'let _ = Exact_output.admit_flow' >>"${target}"
  if
    MASC_COMPACTION_BOUNDARY_ROOT="${fixture}" \
      MASC_COMPACTION_EXACT_FLOW_TARGET="${target}" \
      "${BASH_SOURCE[0]}" --check-only >/dev/null 2>&1
  then
    fail "self-test retired admission unexpectedly passed"
  fi
  cp "${clean}" "${target}"

  printf '%s\n' 'let _ = Exact_output.receipt_phase' >>"${target}"
  if
    MASC_COMPACTION_BOUNDARY_ROOT="${fixture}" \
      MASC_COMPACTION_EXACT_FLOW_TARGET="${target}" \
      "${BASH_SOURCE[0]}" --check-only >/dev/null 2>&1
  then
    fail "self-test forbidden receipt inspection unexpectedly passed"
  fi
  cp "${clean}" "${target}"

  printf '%s\n' 'let provider_id = "forbidden"' >>"${adjacent}"
  if
    MASC_COMPACTION_BOUNDARY_ROOT="${fixture}" \
      MASC_COMPACTION_EXACT_FLOW_TARGET="${target}" \
      "${BASH_SOURCE[0]}" --check-only >/dev/null 2>&1
  then
    fail "self-test provider/model projection unexpectedly passed"
  fi
  cp "${adjacent_clean}" "${adjacent}"

  printf '%s\n' 'let _ = ()' \
    >"${fixture}/lib/keeper/keeper_compaction_projection_target.ml"
  if
    MASC_COMPACTION_BOUNDARY_ROOT="${fixture}" \
      MASC_COMPACTION_EXACT_FLOW_TARGET="${target}" \
      "${BASH_SOURCE[0]}" --check-only >/dev/null 2>&1
  then
    fail "self-test retired projection carrier unexpectedly passed"
  fi
  echo \
    "[compaction-exact-flow-boundary:self-test] clean=pass unrelated=pass duplicate=fail missing=fail legacy=fail forbidden=fail projection=fail carrier=fail"
}

case "${1:-}" in
  --self-test)
    self_test
    ;;
  --check-only | "")
    check_boundary
    ;;
  *)
    fail "usage: $0 [--self-test|--check-only]"
    ;;
esac
