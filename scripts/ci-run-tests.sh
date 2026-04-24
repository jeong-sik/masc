#!/usr/bin/env bash
set -euo pipefail

# CI test runner with:
# 1) periodic heartbeat logs (prevents "silent hang" confusion),
# 2) explicit timeout,
# 3) diagnostics dump on timeout/failure.

mktemp_ci_log() {
  local tmp_dir="${TMPDIR:-/tmp}"
  local path=""
  if path="$(mktemp "${tmp_dir%/}/ci-run-tests.XXXXXX.log" 2>/dev/null)"; then
    printf '%s' "${path}"
  else
    mktemp "${tmp_dir%/}/ci-run-tests.XXXXXX"
  fi
}

if [[ -n "${1:-}" ]]; then
  TEST_CMD="$1"
elif [[ "${GITHUB_ACTIONS:-}" != "true" && -x "scripts/dune-local.sh" ]]; then
  TEST_CMD="scripts/dune-local.sh test"
else
  TEST_CMD="opam exec -- dune test"
fi
TEST_TIMEOUT_SEC="${CI_TEST_TIMEOUT_SEC:-1200}"
HEARTBEAT_SEC="${CI_TEST_HEARTBEAT_SEC:-30}"
START_EPOCH="$(date +%s)"
TEST_LOG_FILE="${CI_TEST_LOG_FILE:-$(mktemp_ci_log)}"
CI_TEST_ALLOW_CLEAN_RETRY="${CI_TEST_ALLOW_CLEAN_RETRY:-1}"
CI_TEST_CLEAN_RETRY_DONE=0
CI_TEST_ALLOW_RPC_RETRY="${CI_TEST_ALLOW_RPC_RETRY:-1}"
CI_TEST_RPC_RETRY_DONE=0
CI_TEST_ALLOW_FLAKY_RETRY="${CI_TEST_ALLOW_FLAKY_RETRY:-1}"
CI_TEST_FLAKY_RETRY_DONE=0
CI_TEST_DISK_FULL_GUIDANCE_DONE=0
CI_TEST_ISOLATED_BUILD_DIR="${CI_TEST_ISOLATED_BUILD_DIR:-.ci_build}"
CI_CONTRACT_HARNESS_ENABLED="${CI_CONTRACT_HARNESS_ENABLED:-0}"
CI_CONTRACT_HARNESS_CMD="${CI_CONTRACT_HARNESS_CMD:-scripts/harness/contract/run_all.sh}"
CI_CONTRACT_HARNESS_TIMEOUT_SEC="${CI_CONTRACT_HARNESS_TIMEOUT_SEC:-900}"
ACTIVE_TEST_BUILD_DIR="${DUNE_BUILD_DIR:-_build}"
ACTIVE_CMD_PID=""
ACTIVE_CMD_PGID=""
ACTIVE_LOG_TAIL_PID=""
CI_LAST_TIMEOUT_DIAG_DONE=0

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

elapsed_sec() {
  local now
  now="$(date +%s)"
  echo $((now - START_EPOCH))
}

log_line() {
  local line="$1"
  printf '%s\n' "${line}" | tee -a "${TEST_LOG_FILE}"
}

tmpdir_disk_usage() {
  local tmp_dir="${TMPDIR:-/tmp}"
  df -h "${tmp_dir}" 2>/dev/null \
    | awk 'NR == 2 { print "size=" $2 " used=" $3 " avail=" $4 " capacity=" $5; found=1 } END { if (!found) print "unknown" }'
}

active_cmd_tree_pids() {
  local root_pid="${ACTIVE_CMD_PID:-}"
  local all_pairs=""
  local known=()
  local changed=1
  local pid=""
  local ppid=""

  if [[ -z "${root_pid}" ]]; then
    return 0
  fi

  known=("${root_pid}")
  all_pairs="$(ps -axo pid=,ppid= 2>/dev/null || true)"

  while [[ "${changed}" -eq 1 ]]; do
    changed=0
    while read -r pid ppid; do
      [[ -n "${pid}" ]] || continue
      [[ -n "${ppid}" ]] || continue
      for candidate in "${known[@]}"; do
        if [[ "${ppid}" = "${candidate}" ]]; then
          local already_seen=0
          local existing=""
          for existing in "${known[@]}"; do
            if [[ "${existing}" = "${pid}" ]]; then
              already_seen=1
              break
            fi
          done
          if [[ "${already_seen}" -eq 0 ]]; then
            known+=("${pid}")
            changed=1
          fi
          break
        fi
      done
    done <<< "${all_pairs}"
  done

  printf '%s\n' "${known[@]}"
}

kill_active_cmd_tree() {
  local signal="${1:-TERM}"
  local -a tree_pids=()
  local pid=""

  while IFS= read -r pid; do
    [[ -n "${pid}" ]] && tree_pids+=("${pid}")
  done < <(active_cmd_tree_pids)

  if [[ "${#tree_pids[@]}" -eq 0 ]]; then
    return 0
  fi

  local idx=0
  for (( idx=${#tree_pids[@]}-1; idx>=0; idx-- )); do
    kill "-${signal}" "${tree_pids[idx]}" >/dev/null 2>&1 || true
  done
}

if [[ -z "${TEST_TIMEOUT_SEC}" || "${TEST_TIMEOUT_SEC}" -le 0 ]]; then
  TEST_TIMEOUT_SEC=1200
fi
if [[ -z "${HEARTBEAT_SEC}" || "${HEARTBEAT_SEC}" -le 0 ]]; then
  HEARTBEAT_SEC=30
fi

diag_dump() {
  local reason="${1:-unknown}"
  echo "[ci-diag] reason=${reason}"
  echo "[ci-diag] timestamp=$(iso_now)"
  echo "[ci-diag] elapsed_sec=$(elapsed_sec)"
  echo "[ci-diag] pwd=$(pwd)"
  echo "[ci-diag] test_cmd=${TEST_CMD}"
  echo "[ci-diag] log_file=${TEST_LOG_FILE}"
  echo "[ci-diag] build_dir=${ACTIVE_TEST_BUILD_DIR}"
  echo "[ci-diag] active_cmd_pid=${ACTIVE_CMD_PID:-<none>}"
  echo "[ci-diag] active_cmd_pgid=${ACTIVE_CMD_PGID:-<none>}"
  echo "[ci-diag] env DUNE_RPC=${DUNE_RPC:-<unset>}"

  echo "[ci-diag] ulimit -n (open files): $(ulimit -n 2>/dev/null || echo unknown)"
  echo "[ci-diag] tmpdir usage: $(tmpdir_disk_usage)"
  echo "[ci-diag] process snapshot (dune/ocaml/test):"
  ps -eo pid,ppid,etime,%cpu,%mem,comm,args \
    | grep -Ei 'dune|ocaml|alcotest|test_' \
    | grep -v grep \
    || true

  if [[ -n "${ACTIVE_CMD_PID}" || -n "${ACTIVE_CMD_PGID}" ]]; then
    echo "[ci-diag] active command process tree snapshot:"
    local tree_pids=()
    local pid=""
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] && tree_pids+=("${pid}")
    done < <(active_cmd_tree_pids)
    if [[ "${#tree_pids[@]}" -gt 0 ]]; then
      local tree_filter=""
      for pid in "${tree_pids[@]}"; do
        tree_filter+=" ${pid} "
      done
      ps -axo pid=,ppid=,pgid=,etime=,%cpu=,%mem=,command= \
        | awk -v wanted="${tree_filter}" 'index(wanted, " " $1 " ") > 0 { print }' \
        || true
    fi
  fi

  local dune_log="${ACTIVE_TEST_BUILD_DIR%/}/log"
  if [[ -f "${dune_log}" ]]; then
    echo "[ci-diag] tail -n 120 ${dune_log}"
    tail -n 120 "${dune_log}" || true
  else
    echo "[ci-diag] no dune log yet: ${dune_log}"
  fi

  if [[ -f "${TEST_LOG_FILE}" ]]; then
    echo "[ci-diag] started suites (latest 10):"
    grep -n '^Testing `' "${TEST_LOG_FILE}" | tail -n 10 || true

    echo "[ci-diag] failure markers (latest 20):"
    grep -En '\[FAIL\]|FAILURE|Test Failed|Fatal error|ASSERT false|Process completed with exit code' "${TEST_LOG_FILE}" | tail -n 20 || true

    echo "[ci-diag] log tail -n 120 ${TEST_LOG_FILE}"
    tail -n 120 "${TEST_LOG_FILE}" || true
  fi

  local tests_root="${ACTIVE_TEST_BUILD_DIR%/}/default/test/_build/_tests"
  if [[ -d "${tests_root}" ]]; then
    # Sort by file mtime so diagnostic tail follows the most recently updated test.
    local -a output_files=()
    local -a latest_outputs=()
    while IFS= read -r line; do
      output_files+=("${line}")
    done < <(find "${tests_root}" -type f -name "*.output" -print 2>/dev/null || true)
    if [[ "${#output_files[@]}" -gt 0 ]]; then
      while IFS= read -r line; do
        latest_outputs+=("${line}")
      done < <(ls -1t "${output_files[@]}" 2>/dev/null | head -n 20 || true)
    fi
    echo "[ci-diag] test output files (latest 20 by mtime):"
    printf '%s\n' "${latest_outputs[@]}" || true

    # Print tail of the most recently updated output file for quick signal.
    local last_output=""
    if [[ "${#latest_outputs[@]}" -gt 0 ]]; then
      last_output="${latest_outputs[0]}"
    fi
    if [[ -n "${last_output}" && -f "${last_output}" ]]; then
      echo "[ci-diag] tail -n 120 ${last_output}"
      tail -n 120 "${last_output}" || true
    fi
  else
    echo "[ci-diag] no test output directory yet: ${tests_root}"
  fi
}

heartbeat() {
  while true; do
    echo "[ci-heartbeat] $(iso_now) elapsed_sec=$(elapsed_sec) dune test still running"
    sleep "${HEARTBEAT_SEC}"
  done
}

test_cmd_needs_dune_sanitization() {
  ([[ "${TEST_CMD}" == *"dune "* ]] || [[ "${TEST_CMD}" == *"dune-local.sh"* ]]) \
    && [[ "${TEST_CMD}" != *"unset DUNE_RPC"* ]]
}

test_cmd_has_explicit_build_dir() {
  [[ "${TEST_CMD}" == *"--build-dir"* ]] || [[ "${TEST_CMD}" == *"DUNE_BUILD_DIR="* ]]
}

effective_test_cmd() {
  if test_cmd_needs_dune_sanitization; then
    printf 'unset DUNE_RPC; %s' "${TEST_CMD}"
  else
    printf '%s' "${TEST_CMD}"
  fi
}

isolated_build_dir_cmd() {
  local cmd="${1}"
  printf 'export DUNE_BUILD_DIR=%q; %s' "${ACTIVE_TEST_BUILD_DIR}" "${cmd}"
}

cache_disabled_cmd() {
  local cmd="${1}"
  if [[ "${cmd}" == *"DUNE_CACHE=disabled"* ]]; then
    printf '%s' "${cmd}"
  else
    printf 'export DUNE_CACHE=disabled; %s' "${cmd}"
  fi
}

agent_sdk_interface_mismatch_detected() {
  [[ -f "${TEST_LOG_FILE}" ]] || return 1
  grep -Eq \
    'Unbound module Agent_sdk|Unbound module Llm_provider|module Oas is an alias for module Agent_sdk|make inconsistent assumptions|inconsistent assumptions over interface Agent_sdk|over interface Llm_provider__|/lib/agent_sdk/[^[:space:]]+[.]cmxa' \
    "${TEST_LOG_FILE}"
}

disk_full_detected() {
  [[ -f "${TEST_LOG_FILE}" ]] || return 1
  grep -Eiq 'No space left on device|dune_trace_write[(][)]|ENOSPC' \
    "${TEST_LOG_FILE}"
}

log_disk_full_guidance() {
  if [[ "${CI_TEST_DISK_FULL_GUIDANCE_DONE}" -eq 1 ]]; then
    return 0
  fi

  CI_TEST_DISK_FULL_GUIDANCE_DONE=1
  local opam_path="${OPAM_SWITCH_PREFIX:-${HOME:-}/.opam}"
  log_line "[ci-run] ERROR: detected disk exhaustion during dune build"
  log_line "[ci-run] repair: df -h . ${opam_path} /tmp"
  log_line "[ci-run] repair: bash scripts/disk-hygiene.sh --fix"
  log_line "[ci-run] repair: bash scripts/disk-hygiene.sh --fix --reset-dune-cache # if dune cache artifacts remain inconsistent"
}

rpc_server_not_running_detected() {
  [[ -f "${TEST_LOG_FILE}" ]] || return 1
  grep -Eq 'RPC server not running\.|has locked the build directory\.' "${TEST_LOG_FILE}"
}

clean_current_build_dir() {
  if [[ "${ACTIVE_TEST_BUILD_DIR}" != "_build" ]]; then
    env DUNE_BUILD_DIR="${ACTIVE_TEST_BUILD_DIR}" dune clean --root . \
      >> "${TEST_LOG_FILE}" 2>&1
  else
    dune clean --root . >> "${TEST_LOG_FILE}" 2>&1
  fi
}

run_agent_sdk_clean_retry() {
  CI_TEST_CLEAN_RETRY_DONE=1
  run_cmd="$(cache_disabled_cmd "${run_cmd}")"
  log_line "[ci-run] WARN: detected Agent_sdk/OAS artifact or interface mismatch; running dune clean and retrying once with DUNE_CACHE=disabled"
  log_line "[ci-run] retry_command: ${run_cmd}"
  clean_current_build_dir
  log_line "[ci-run] retry_started_at=$(iso_now)"
  set +e
  run_with_timeout "${run_cmd}"
  status=$?
  set -e
}

run_with_timeout() {
  local cmd="${1}"
  local deadline=0
  local status=0
  local kill_grace_sec=5

  ACTIVE_CMD_PID=""
  ACTIVE_CMD_PGID=""
  ACTIVE_LOG_TAIL_PID=""
  CI_LAST_TIMEOUT_DIAG_DONE=0

  tail -n 0 -f "${TEST_LOG_FILE}" &
  ACTIVE_LOG_TAIL_PID=$!

  bash -lc "${cmd}" >> "${TEST_LOG_FILE}" 2>&1 &
  ACTIVE_CMD_PID=$!
  ACTIVE_CMD_PGID="$(
    ps -o pgid= -p "${ACTIVE_CMD_PID}" 2>/dev/null \
      | tr -d '[:space:]'
  )"

  if [[ "${TEST_TIMEOUT_SEC}" -gt 0 ]]; then
    deadline=$(( $(date +%s) + TEST_TIMEOUT_SEC ))
  fi

  while kill -0 "${ACTIVE_CMD_PID}" >/dev/null 2>&1; do
    if [[ "${deadline}" -gt 0 ]] && [[ "$(date +%s)" -ge "${deadline}" ]]; then
      CI_LAST_TIMEOUT_DIAG_DONE=1
      diag_dump "timeout"
      kill_active_cmd_tree TERM
      sleep "${kill_grace_sec}"
      if kill -0 "${ACTIVE_CMD_PID}" >/dev/null 2>&1; then
        kill_active_cmd_tree KILL
      fi
      wait "${ACTIVE_CMD_PID}" >/dev/null 2>&1 || true
      if [[ -n "${ACTIVE_LOG_TAIL_PID}" ]]; then
        kill "${ACTIVE_LOG_TAIL_PID}" >/dev/null 2>&1 || true
        wait "${ACTIVE_LOG_TAIL_PID}" >/dev/null 2>&1 || true
      fi
      ACTIVE_CMD_PID=""
      ACTIVE_CMD_PGID=""
      ACTIVE_LOG_TAIL_PID=""
      return 124
    fi
    sleep 1
  done

  status=0
  wait "${ACTIVE_CMD_PID}" || status=$?
  if [[ -n "${ACTIVE_LOG_TAIL_PID}" ]]; then
    kill "${ACTIVE_LOG_TAIL_PID}" >/dev/null 2>&1 || true
    wait "${ACTIVE_LOG_TAIL_PID}" >/dev/null 2>&1 || true
  fi
  ACTIVE_CMD_PID=""
  ACTIVE_CMD_PGID=""
  ACTIVE_LOG_TAIL_PID=""
  return "${status}"
}

hb_pid=""
cleanup() {
  if [[ -n "${hb_pid}" ]]; then
    kill "${hb_pid}" >/dev/null 2>&1 || true
    wait "${hb_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${ACTIVE_LOG_TAIL_PID}" ]]; then
    kill "${ACTIVE_LOG_TAIL_PID}" >/dev/null 2>&1 || true
    wait "${ACTIVE_LOG_TAIL_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

log_line "[ci-run] command: ${TEST_CMD}"
if test_cmd_needs_dune_sanitization; then
  log_line "[ci-run] sanitized_command: $(effective_test_cmd)"
fi
log_line "[ci-run] timeout_sec=${TEST_TIMEOUT_SEC} heartbeat_sec=${HEARTBEAT_SEC}"
log_line "[ci-run] started_at=$(iso_now)"
log_line "[ci-run] log_file=${TEST_LOG_FILE}"

heartbeat &
hb_pid="$!"

effective_cmd="$(effective_test_cmd)"
run_cmd="${effective_cmd}"

set +e
run_with_timeout "${run_cmd}"
status=$?
set -e

if [[ "${status}" -ne 0 ]] && disk_full_detected; then
  log_disk_full_guidance
fi

if [[ "${status}" -ne 0 ]] \
  && [[ "${CI_TEST_ALLOW_RPC_RETRY}" = "1" ]] \
  && [[ "${CI_TEST_RPC_RETRY_DONE}" -eq 0 ]] \
  && test_cmd_needs_dune_sanitization \
  && ! test_cmd_has_explicit_build_dir \
  && rpc_server_not_running_detected; then
  CI_TEST_RPC_RETRY_DONE=1
  ACTIVE_TEST_BUILD_DIR="${CI_TEST_ISOLATED_BUILD_DIR}"
  run_cmd="$(isolated_build_dir_cmd "${effective_cmd}")"
  log_line "[ci-run] WARN: detected dune RPC/lock failure; retrying once with isolated build dir ${ACTIVE_TEST_BUILD_DIR}"
  log_line "[ci-run] isolated_command: ${run_cmd}"
  log_line "[ci-run] retry_started_at=$(iso_now)"
  set +e
  run_with_timeout "${run_cmd}"
  status=$?
  set -e
fi

if [[ "${status}" -ne 0 ]] \
  && [[ "${CI_TEST_ALLOW_CLEAN_RETRY}" = "1" ]] \
  && [[ "${CI_TEST_CLEAN_RETRY_DONE}" -eq 0 ]] \
  && test_cmd_needs_dune_sanitization \
  && agent_sdk_interface_mismatch_detected; then
  run_agent_sdk_clean_retry
fi

if [[ "${status}" -eq 124 ]]; then
  if [[ "${CI_LAST_TIMEOUT_DIAG_DONE}" -eq 0 ]]; then
    diag_dump "timeout"
  fi
  log_line "[ci-run] ERROR: test command timed out after ${TEST_TIMEOUT_SEC}s"
  exit 124
fi

# Flaky-test retry: if the test failed for reasons not caught by the
# specific retry handlers above (RPC lock, interface mismatch), retry
# once with an isolated build dir. This covers CI-only resource
# exhaustion (fd/tmpdir) that cannot be reproduced locally.
# See: https://github.com/jeong-sik/masc-mcp/issues/2957
if [[ "${status}" -ne 0 ]] \
  && [[ "${CI_TEST_ALLOW_FLAKY_RETRY}" = "1" ]] \
  && [[ "${CI_TEST_FLAKY_RETRY_DONE}" -eq 0 ]] \
  && [[ "${CI_TEST_RPC_RETRY_DONE}" -eq 0 ]] \
  && [[ "${CI_TEST_CLEAN_RETRY_DONE}" -eq 0 ]] \
  && test_cmd_needs_dune_sanitization \
  && ! disk_full_detected; then
  CI_TEST_FLAKY_RETRY_DONE=1
  diag_dump "flaky_pre_retry_${status}"
  ACTIVE_TEST_BUILD_DIR="${CI_TEST_ISOLATED_BUILD_DIR}_flaky"
  run_cmd="$(isolated_build_dir_cmd "${effective_cmd}")"
  log_line "[ci-run] WARN: test failed (exit=${status}); retrying once with isolated build dir ${ACTIVE_TEST_BUILD_DIR} (flaky-test mitigation)"
  log_line "[ci-run] flaky_retry_started_at=$(iso_now)"
  set +e
  run_with_timeout "${run_cmd}"
  status=$?
  set -e

  if [[ "${status}" -ne 0 ]] && disk_full_detected; then
    log_disk_full_guidance
  fi
fi

if [[ "${status}" -ne 0 ]] \
  && [[ "${CI_TEST_ALLOW_CLEAN_RETRY}" = "1" ]] \
  && [[ "${CI_TEST_CLEAN_RETRY_DONE}" -eq 0 ]] \
  && test_cmd_needs_dune_sanitization \
  && agent_sdk_interface_mismatch_detected; then
  run_agent_sdk_clean_retry
fi

if [[ "${status}" -ne 0 ]]; then
  if disk_full_detected; then
    log_disk_full_guidance
  fi
  diag_dump "nonzero_exit_${status}"
  log_line "[ci-run] ERROR: test command failed with exit=${status}"
  exit "${status}"
fi

if [[ "${CI_CONTRACT_HARNESS_ENABLED}" = "1" ]]; then
  log_line "[ci-run] contract_harness_command: ${CI_CONTRACT_HARNESS_CMD}"
  log_line "[ci-run] contract_harness_timeout_sec=${CI_CONTRACT_HARNESS_TIMEOUT_SEC}"
  saved_timeout_sec="${TEST_TIMEOUT_SEC}"
  TEST_TIMEOUT_SEC="${CI_CONTRACT_HARNESS_TIMEOUT_SEC}"
  set +e
  run_with_timeout "${CI_CONTRACT_HARNESS_CMD}"
  contract_status=$?
  set -e
  TEST_TIMEOUT_SEC="${saved_timeout_sec}"

  if [[ "${contract_status}" -eq 124 ]]; then
    diag_dump "contract_harness_timeout"
    log_line "[ci-run] ERROR: contract harness timed out after ${CI_CONTRACT_HARNESS_TIMEOUT_SEC}s"
    exit 124
  fi

  if [[ "${contract_status}" -ne 0 ]]; then
    diag_dump "contract_harness_exit_${contract_status}"
    log_line "[ci-run] ERROR: contract harness failed with exit=${contract_status}"
    exit "${contract_status}"
  fi

  log_line "[ci-run] contract harness completed successfully"
else
  log_line "[ci-run] contract harness skipped (CI_CONTRACT_HARNESS_ENABLED=${CI_CONTRACT_HARNESS_ENABLED})"
fi

log_line "[ci-run] tests completed successfully (elapsed_sec=$(elapsed_sec))"
