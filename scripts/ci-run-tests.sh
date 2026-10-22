#!/usr/bin/env bash
set -euo pipefail

# CI test observer. Commands run exactly once. Callers may set a finite
# CI_TEST_TIMEOUT_SEC; expiry reports diagnostics, cancels the owned session,
# and exits 124. Cleanup uncertainty is explicit; setsid escapes are outside
# this boundary. No retry path exists.

mktemp_ci_log() {
  local tmp_dir="${TMPDIR:-/tmp}"
  local path=""
  if path="$(mktemp "${tmp_dir%/}/ci-run-tests.XXXXXX.log" 2>/dev/null)"; then
    printf '%s' "${path}"
  else
    mktemp "${tmp_dir%/}/ci-run-tests.XXXXXX"
  fi
}

if [[ "${1:-}" = "--ci-run-diagnostics" ]]; then
  TEST_CMD="${CI_DIAG_TEST_CMD:?missing observed command}"
elif [[ -n "${1:-}" ]]; then
  TEST_CMD="$1"
elif [[ "${GITHUB_ACTIONS:-}" != "true" && -x "scripts/dune-local.sh" ]]; then
  TEST_CMD="scripts/dune-local.sh test"
else
  TEST_CMD="opam exec -- dune test --root ."
fi

HEARTBEAT_SEC="${CI_TEST_HEARTBEAT_SEC:-30}"
TEST_TIMEOUT_SEC="${CI_TEST_TIMEOUT_SEC:-0}"
TEST_TIMEOUT_GRACE_SEC="${CI_TEST_TIMEOUT_GRACE_SEC:-5}"

now_epoch() {
  date +%s
}

START_EPOCH="${CI_TEST_START_EPOCH:-$(now_epoch)}"
TEST_LOG_FILE="${CI_TEST_LOG_FILE:-$(mktemp_ci_log)}"
DUNE_SOURCEROOT="${DUNE_SOURCEROOT:-$(pwd -P)}"
export DUNE_SOURCEROOT
CI_TEST_DISK_MIN_AVAILABLE_MB="${CI_TEST_DISK_MIN_AVAILABLE_MB:-1024}"
CI_TEST_DISK_CHECK_SEC="${CI_TEST_DISK_CHECK_SEC:-10}"
CI_CONTRACT_HARNESS_ENABLED="${CI_CONTRACT_HARNESS_ENABLED:-0}"
CI_CONTRACT_HARNESS_CMD="${CI_CONTRACT_HARNESS_CMD:-scripts/harness/contract/run_all.sh}"
ACTIVE_TEST_BUILD_DIR="${DUNE_BUILD_DIR:-_build}"
ACTIVE_CMD_PID="${CI_DIAG_ACTIVE_PID:-}"
ACTIVE_CMD_PGID="${CI_DIAG_ACTIVE_PID:-}"

if [[ -z "${HEARTBEAT_SEC}" || "${HEARTBEAT_SEC}" -le 0 ]]; then
  HEARTBEAT_SEC=30
fi
if [[ ! "${TEST_TIMEOUT_SEC}" =~ ^[0-9]+$ ]]; then
  echo "[ci-run] ERROR: CI_TEST_TIMEOUT_SEC must be a non-negative integer" >&2
  exit 2
fi
TEST_TIMEOUT_SEC="$((10#${TEST_TIMEOUT_SEC}))"
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
  now="$(now_epoch)"
  echo $((now - START_EPOCH))
}

tmpdir_disk_usage() {
  local tmp_dir="${TMPDIR:-/tmp}"
  df -h "${tmp_dir}" 2>/dev/null \
    | awk 'NR == 2 { print "size=" $2 " used=" $3 " avail=" $4 " capacity=" $5; found=1 } END { if (!found) print "unknown" }'
}

# Where the space went, printed only when the observer reports disk pressure.
# df says the disk is full; it does not say which tree filled it. Each du is
# bounded so a slow walk over a huge tree cannot outlast the diagnostics.
disk_pressure_usage() {
  local build_dir="${ACTIVE_TEST_BUILD_DIR%/}"
  local path=""
  echo "[ci-diag] disk usage by path (MB):"
  for path in \
    "${build_dir}/default" \
    "${build_dir}/.sandbox" \
    "${TMPDIR:-/tmp}" \
    "${RUNNER_TEMP:-}" \
    "${HOME:-}/.cache"; do
    [[ -n "${path}" && -e "${path}" ]] || continue
    timeout 60 du -sm "${path}" 2>/dev/null || echo "unknown ${path}"
  done
  if [[ -d /var/lib/docker ]]; then
    timeout 60 sudo -n du -sm /var/lib/docker 2>/dev/null \
      || echo "unknown /var/lib/docker"
  fi
  if command -v docker >/dev/null 2>&1; then
    echo "[ci-diag] docker system df:"
    timeout 60 docker system df 2>/dev/null || echo "unknown"
    echo "[ci-diag] docker containers: $(timeout 30 docker ps -aq 2>/dev/null | wc -l)"
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
  if [[ "${reason}" = "disk_pressure_observed" ]]; then
    disk_pressure_usage
  fi
  # Runner processes may carry credentials in argv. Emit executable names only.
  echo "[ci-diag] process snapshot (dune/ocaml/test):"
  ps -eo pid,ppid,pgid,etime,%cpu,%mem,comm \
    | grep -Ei 'dune|ocaml|alcotest|test_' \
    || true

  echo "[ci-diag] global process snapshot:"
  ps -eo pid,ppid,pgid,etime,%cpu,%mem,comm || true

  if [[ -n "${ACTIVE_CMD_PID}" ]]; then
    echo "[ci-diag] active command process tree snapshot:"
    local tree_filter=""
    local pid=""
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] && tree_filter+=" ${pid} "
    done < <(active_cmd_tree_pids)
    if [[ -n "${tree_filter}" ]]; then
      ps -axo pid=,ppid=,pgid=,etime=,%cpu=,%mem=,comm= \
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

# Diagnostics are read-only. No discovered PID can become signal authority.
if [[ "${1:-}" = "--ci-run-diagnostics" ]]; then
  diag_dump "${2:-unknown}"
  exit 0
fi

export CI_TEST_LOG_FILE="${TEST_LOG_FILE}" CI_TEST_START_EPOCH="${START_EPOCH}"
export CI_TEST_HEARTBEAT_SEC="${HEARTBEAT_SEC}" CI_TEST_TIMEOUT_SEC="${TEST_TIMEOUT_SEC}"
export CI_TEST_TIMEOUT_GRACE_SEC="${TEST_TIMEOUT_GRACE_SEC}"
export CI_TEST_DISK_MIN_AVAILABLE_MB CI_TEST_DISK_CHECK_SEC CI_CONTRACT_HARNESS_ENABLED
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 "${SCRIPT_DIR}/ci/command_observer.py" "${TEST_CMD}" "${CI_CONTRACT_HARNESS_CMD}"
