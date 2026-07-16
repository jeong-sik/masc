#!/usr/bin/env bash
set -euo pipefail

# CI test observer. The workflow job owns the outer execution boundary.
# This script reports progress and diagnostics, but never terminates or retries
# the command it observes.

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
  TEST_CMD="opam exec -- dune test --root ."
fi

HEARTBEAT_SEC="${CI_TEST_HEARTBEAT_SEC:-30}"
START_EPOCH="$(date +%s)"
TEST_LOG_FILE="${CI_TEST_LOG_FILE:-$(mktemp_ci_log)}"
DUNE_SOURCEROOT="${DUNE_SOURCEROOT:-$(pwd -P)}"
export DUNE_SOURCEROOT
CI_TEST_DISK_MIN_AVAILABLE_MB="${CI_TEST_DISK_MIN_AVAILABLE_MB:-1024}"
CI_TEST_DISK_CHECK_SEC="${CI_TEST_DISK_CHECK_SEC:-10}"
CI_CONTRACT_HARNESS_ENABLED="${CI_CONTRACT_HARNESS_ENABLED:-0}"
CI_CONTRACT_HARNESS_CMD="${CI_CONTRACT_HARNESS_CMD:-scripts/harness/contract/run_all.sh}"
ACTIVE_TEST_BUILD_DIR="${DUNE_BUILD_DIR:-_build}"
ACTIVE_CMD_PID=""
ACTIVE_CMD_PGID=""
ACTIVE_LOG_TAIL_PID=""
DISK_PRESSURE_REPORTED=0

if [[ -z "${HEARTBEAT_SEC}" || "${HEARTBEAT_SEC}" -le 0 ]]; then
  HEARTBEAT_SEC=30
fi
if [[ -z "${CI_TEST_DISK_MIN_AVAILABLE_MB}" || "${CI_TEST_DISK_MIN_AVAILABLE_MB}" -lt 0 ]]; then
  CI_TEST_DISK_MIN_AVAILABLE_MB=1024
fi
if [[ -z "${CI_TEST_DISK_CHECK_SEC}" || "${CI_TEST_DISK_CHECK_SEC}" -le 0 ]]; then
  CI_TEST_DISK_CHECK_SEC=10
fi

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

elapsed_sec() {
  local now
  now="$(date +%s)"
  echo $((now - START_EPOCH))
}

log_line() {
  printf '%s\n' "$1" | tee -a "${TEST_LOG_FILE}"
}

tmpdir_disk_usage() {
  local tmp_dir="${TMPDIR:-/tmp}"
  df -h "${tmp_dir}" 2>/dev/null \
    | awk 'NR == 2 { print "size=" $2 " used=" $3 " avail=" $4 " capacity=" $5; found=1 } END { if (!found) print "unknown" }'
}

disk_available_mb() {
  df -Pm "${1:-${DUNE_SOURCEROOT}}" 2>/dev/null \
    | awk 'NR == 2 { print $4; found=1 } END { if (!found) print "" }'
}

disk_pressure_detected() {
  [[ "${CI_TEST_DISK_MIN_AVAILABLE_MB}" -gt 0 ]] || return 1
  local avail_mb=""
  avail_mb="$(disk_available_mb "${DUNE_SOURCEROOT}")"
  [[ "${avail_mb}" =~ ^[0-9]+$ ]] || return 1
  [[ "${avail_mb}" -le "${CI_TEST_DISK_MIN_AVAILABLE_MB}" ]]
}

disk_pressure_detail() {
  local avail_mb=""
  avail_mb="$(disk_available_mb "${DUNE_SOURCEROOT}")"
  if [[ "${avail_mb}" =~ ^[0-9]+$ ]]; then
    printf 'path=%s available_mb=%s min_available_mb=%s' \
      "${DUNE_SOURCEROOT}" "${avail_mb}" "${CI_TEST_DISK_MIN_AVAILABLE_MB}"
  else
    printf 'path=%s available_mb=unknown min_available_mb=%s' \
      "${DUNE_SOURCEROOT}" "${CI_TEST_DISK_MIN_AVAILABLE_MB}"
  fi
}

active_cmd_tree_pids() {
  local root_pid="${ACTIVE_CMD_PID:-}"
  local all_pairs=""
  local known=()
  local changed=1
  local pid=""
  local ppid=""

  [[ -n "${root_pid}" ]] || return 0
  known=("${root_pid}")
  all_pairs="$(ps -axo pid=,ppid= 2>/dev/null || true)"

  while [[ "${changed}" -eq 1 ]]; do
    changed=0
    while read -r pid ppid; do
      [[ -n "${pid}" && -n "${ppid}" ]] || continue
      for candidate in "${known[@]}"; do
        if [[ "${ppid}" = "${candidate}" ]]; then
          local already_seen=0
          for existing in "${known[@]}"; do
            [[ "${existing}" = "${pid}" ]] && already_seen=1 && break
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
  echo "[ci-diag] tmpdir usage: $(tmpdir_disk_usage)"
  echo "[ci-diag] process snapshot (dune/ocaml/test):"
  ps -eo pid,ppid,etime,%cpu,%mem,comm,args \
    | grep -Ei 'dune|ocaml|alcotest|test_' \
    | grep -v grep \
    || true

  if [[ -n "${ACTIVE_CMD_PID}" ]]; then
    echo "[ci-diag] active command process tree snapshot:"
    local tree_filter=""
    local pid=""
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] && tree_filter+=" ${pid} "
    done < <(active_cmd_tree_pids)
    if [[ -n "${tree_filter}" ]]; then
      ps -axo pid=,ppid=,pgid=,etime=,%cpu=,%mem=,command= \
        | awk -v wanted="${tree_filter}" 'index(wanted, " " $1 " ") > 0 { print }' \
        || true
    fi
  fi

  local dune_log="${ACTIVE_TEST_BUILD_DIR%/}/log"
  if [[ -f "${dune_log}" ]]; then
    echo "[ci-diag] tail -n 120 ${dune_log}"
    tail -n 120 "${dune_log}" || true
  fi
  if [[ -f "${TEST_LOG_FILE}" ]]; then
    echo "[ci-diag] log tail -n 120 ${TEST_LOG_FILE}"
    tail -n 120 "${TEST_LOG_FILE}" || true
  fi
}

heartbeat() {
  while true; do
    echo "[ci-heartbeat] $(iso_now) elapsed_sec=$(elapsed_sec) command still running"
    sleep "${HEARTBEAT_SEC}"
  done
}

effective_test_cmd() {
  if ([[ "${TEST_CMD}" == *"dune "* ]] || [[ "${TEST_CMD}" == *"dune-local.sh"* ]]) \
    && [[ "${TEST_CMD}" != *"unset DUNE_RPC"* ]]; then
    printf 'unset DUNE_RPC; %s' "${TEST_CMD}"
  else
    printf '%s' "${TEST_CMD}"
  fi
}

kill_active_cmd_tree() {
  local signal="${1:-TERM}"
  local tree_pids=()
  local pid=""
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] && tree_pids+=("${pid}")
  done < <(active_cmd_tree_pids)
  local idx=0
  for (( idx=${#tree_pids[@]}-1; idx>=0; idx-- )); do
    kill "-${signal}" "${tree_pids[idx]}" >/dev/null 2>&1 || true
  done
}

hb_pid=""
cleanup() {
  if [[ -n "${ACTIVE_CMD_PID}" ]] && kill -0 "${ACTIVE_CMD_PID}" >/dev/null 2>&1; then
    kill_active_cmd_tree TERM
    wait "${ACTIVE_CMD_PID}" >/dev/null 2>&1 || true
  fi
  [[ -z "${hb_pid}" ]] || kill "${hb_pid}" >/dev/null 2>&1 || true
  [[ -z "${ACTIVE_LOG_TAIL_PID}" ]] || kill "${ACTIVE_LOG_TAIL_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

run_observed() {
  local cmd="$1"
  local status=0
  local next_disk_check=$(( $(date +%s) + CI_TEST_DISK_CHECK_SEC ))

  tail -n 0 -f "${TEST_LOG_FILE}" &
  ACTIVE_LOG_TAIL_PID=$!
  bash -l -s <<< "${cmd}" >> "${TEST_LOG_FILE}" 2>&1 &
  ACTIVE_CMD_PID=$!
  ACTIVE_CMD_PGID="$(ps -o pgid= -p "${ACTIVE_CMD_PID}" 2>/dev/null | tr -d '[:space:]')"

  while kill -0 "${ACTIVE_CMD_PID}" >/dev/null 2>&1; do
    local now_epoch
    now_epoch="$(date +%s)"
    if [[ "${now_epoch}" -ge "${next_disk_check}" ]]; then
      next_disk_check=$((now_epoch + CI_TEST_DISK_CHECK_SEC))
      if [[ "${DISK_PRESSURE_REPORTED}" -eq 0 ]] && disk_pressure_detected; then
        DISK_PRESSURE_REPORTED=1
        log_line "[ci-observe] disk_pressure $(disk_pressure_detail)"
        diag_dump "disk_pressure_observed"
      fi
    fi
    sleep 1
  done

  wait "${ACTIVE_CMD_PID}" || status=$?
  kill "${ACTIVE_LOG_TAIL_PID}" >/dev/null 2>&1 || true
  wait "${ACTIVE_LOG_TAIL_PID}" >/dev/null 2>&1 || true
  ACTIVE_CMD_PID=""
  ACTIVE_CMD_PGID=""
  ACTIVE_LOG_TAIL_PID=""
  return "${status}"
}

log_line "[ci-run] command: ${TEST_CMD}"
log_line "[ci-run] heartbeat_sec=${HEARTBEAT_SEC}"
log_line "[ci-run] disk_min_available_mb=${CI_TEST_DISK_MIN_AVAILABLE_MB} disk_check_sec=${CI_TEST_DISK_CHECK_SEC}"
log_line "[ci-run] started_at=$(iso_now)"
log_line "[ci-run] log_file=${TEST_LOG_FILE}"
log_line "[ci-run] source_root=${DUNE_SOURCEROOT}"

heartbeat &
hb_pid=$!

status=0
run_observed "$(effective_test_cmd)" || status=$?
if [[ "${status}" -ne 0 ]]; then
  diag_dump "nonzero_exit_${status}"
  log_line "[ci-run] ERROR: test command failed with exit=${status}"
  exit "${status}"
fi

if [[ "${CI_CONTRACT_HARNESS_ENABLED}" = "1" ]]; then
  log_line "[ci-run] contract_harness_command: ${CI_CONTRACT_HARNESS_CMD}"
  contract_status=0
  run_observed "${CI_CONTRACT_HARNESS_CMD}" || contract_status=$?
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
