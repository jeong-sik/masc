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

  require_once "Exact_output.make_flow_candidate"
  require_once "Exact_output.admit_flow"
  require_once "Exact_output.start_flow"
  require_once "Exact_output.execute_flow_once"

  local forbidden_pattern
  forbidden_pattern='Exact_output\.admit([^_[:alnum:]]|$)|Exact_output\.(start_attempt|execute_once|receipt_phase|receipt_dispatch_count)|Exact_output\.effect_phase|type admitted_slot|is_before_dispatch_zero|ready_plan'
  if rg -n "${forbidden_pattern}" "${TARGET}"; then
    fail "MASC-local exact admission/attempt/receipt control flow is forbidden"
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
  old_pattern="${failed_after}|${failed_before}|${cancelled_after}|${lower_failed_after}|${lower_failed_before}|${lower_cancelled_after}|${attempt_constructor}|${exact_attempt_constructor}|${provenance_constructor}|${exact_provenance_constructor}|\"${provenance_label}\"|\"${attempt_label}\""
  if rg -n "${old_pattern}" "${REPO_ROOT}/lib" "${REPO_ROOT}/test"; then
    fail "retired receipt-phase or legacy durable terminal label remains"
  fi

  echo "[compaction-exact-flow-boundary] OK"
}

self_test() {
  local fixture target
  fixture="$(mktemp -d "${TMPDIR:-/tmp}/compaction-exact-flow-boundary.XXXXXX")"
  trap "rm -rf '${fixture}'" EXIT
  mkdir -p "${fixture}/lib/keeper" "${fixture}/test"
  target="${fixture}/lib/keeper/keeper_compaction_llm_summarizer.ml"
  cat >"${target}" <<'EOF'
let _ = Exact_output.make_flow_candidate
let _ = Exact_output.admit_flow
let _ = Exact_output.start_flow
let _ = Exact_output.execute_flow_once
EOF

  MASC_COMPACTION_BOUNDARY_ROOT="${fixture}" \
    MASC_COMPACTION_EXACT_FLOW_TARGET="${target}" \
    "${BASH_SOURCE[0]}" --check-only >/dev/null

  printf '%s\n' 'let _ = Exact_output.receipt_phase' >>"${target}"
  if
    MASC_COMPACTION_BOUNDARY_ROOT="${fixture}" \
      MASC_COMPACTION_EXACT_FLOW_TARGET="${target}" \
      "${BASH_SOURCE[0]}" --check-only >/dev/null 2>&1
  then
    fail "self-test forbidden receipt inspection unexpectedly passed"
  fi
  echo "[compaction-exact-flow-boundary:self-test] clean=pass forbidden=fail"
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
