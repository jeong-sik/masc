#!/usr/bin/env bash
set -euo pipefail

# CI test runner with:
# 1) periodic heartbeat logs (prevents "silent hang" confusion),
# 2) explicit timeout,
# 3) diagnostics dump on timeout/failure.

TEST_CMD="${1:-opam exec -- dune test}"
TEST_TIMEOUT_SEC="${CI_TEST_TIMEOUT_SEC:-1200}"
HEARTBEAT_SEC="${CI_TEST_HEARTBEAT_SEC:-30}"
START_EPOCH="$(date +%s)"
TEST_LOG_FILE="${CI_TEST_LOG_FILE:-$(mktemp "${TMPDIR:-/tmp}/ci-run-tests.XXXXXX.log")}"

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

elapsed_sec() {
  local now
  now="$(date +%s)"
  echo $((now - START_EPOCH))
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
  echo "[ci-diag] log_file=${TEST_LOG_FILE}"

  echo "[ci-diag] process snapshot (dune/ocaml/test):"
  ps -eo pid,ppid,etime,%cpu,%mem,comm,args \
    | grep -Ei 'dune|ocaml|alcotest|test_' \
    | grep -v grep \
    || true

  if [[ -f "${TEST_LOG_FILE}" ]]; then
    echo "[ci-diag] started suites (latest 10):"
    grep -n '^Testing `' "${TEST_LOG_FILE}" | tail -n 10 || true

    echo "[ci-diag] failure markers (latest 20):"
    grep -En '\[FAIL\]|FAILURE|Test Failed|Fatal error|ASSERT false|Process completed with exit code' "${TEST_LOG_FILE}" | tail -n 20 || true

    echo "[ci-diag] log tail -n 120 ${TEST_LOG_FILE}"
    tail -n 120 "${TEST_LOG_FILE}" || true
  fi

  local tests_root="_build/default/test/_build/_tests"
  if [[ -d "${tests_root}" ]]; then
    # Sort by file mtime so diagnostic tail follows the most recently updated test.
    local -a output_files=()
    local -a latest_outputs=()
    mapfile -t output_files < <(find "${tests_root}" -type f -name "*.output" -print 2>/dev/null || true)
    if [[ "${#output_files[@]}" -gt 0 ]]; then
      mapfile -t latest_outputs < <(ls -1t "${output_files[@]}" 2>/dev/null | head -n 20 || true)
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

run_with_timeout() {
  local timeout_bin=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="gtimeout"
  fi

  if [[ -n "${timeout_bin}" ]]; then
    if "${timeout_bin}" --help 2>&1 | grep -q -- '--foreground'; then
      "${timeout_bin}" --foreground "${TEST_TIMEOUT_SEC}" bash -lc "${TEST_CMD}" \
        > >(tee -a "${TEST_LOG_FILE}") \
        2> >(tee -a "${TEST_LOG_FILE}" >&2)
    else
      "${timeout_bin}" "${TEST_TIMEOUT_SEC}" bash -lc "${TEST_CMD}" \
        > >(tee -a "${TEST_LOG_FILE}") \
        2> >(tee -a "${TEST_LOG_FILE}" >&2)
    fi
  else
    echo "[ci-run] WARN: timeout command not found (timeout/gtimeout); running without enforced timeout"
    bash -lc "${TEST_CMD}" \
      > >(tee -a "${TEST_LOG_FILE}") \
      2> >(tee -a "${TEST_LOG_FILE}" >&2)
  fi
}

hb_pid=""
cleanup() {
  if [[ -n "${hb_pid}" ]]; then
    kill "${hb_pid}" >/dev/null 2>&1 || true
    wait "${hb_pid}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "[ci-run] command: ${TEST_CMD}"
echo "[ci-run] timeout_sec=${TEST_TIMEOUT_SEC} heartbeat_sec=${HEARTBEAT_SEC}"
echo "[ci-run] started_at=$(iso_now)"
echo "[ci-run] log_file=${TEST_LOG_FILE}"

heartbeat &
hb_pid="$!"

set +e
run_with_timeout
status=$?
set -e

if [[ "${status}" -eq 124 ]]; then
  diag_dump "timeout"
  echo "[ci-run] ERROR: test command timed out after ${TEST_TIMEOUT_SEC}s"
  exit 124
fi

if [[ "${status}" -ne 0 ]]; then
  diag_dump "nonzero_exit_${status}"
  echo "[ci-run] ERROR: test command failed with exit=${status}"
  exit "${status}"
fi

echo "[ci-run] tests completed successfully (elapsed_sec=$(elapsed_sec))"
