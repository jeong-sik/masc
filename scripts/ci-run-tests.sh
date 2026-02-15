#!/usr/bin/env bash
set -euo pipefail

# CI test runner with:
# 1) periodic heartbeat logs (prevents "silent hang" confusion),
# 2) explicit timeout,
# 3) diagnostics dump on timeout/failure.

TEST_CMD="${1:-opam exec -- dune test}"
TEST_TIMEOUT_SEC="${CI_TEST_TIMEOUT_SEC:-1200}"
HEARTBEAT_SEC="${CI_TEST_HEARTBEAT_SEC:-30}"

if [[ -z "${TEST_TIMEOUT_SEC}" || "${TEST_TIMEOUT_SEC}" -le 0 ]]; then
  TEST_TIMEOUT_SEC=1200
fi
if [[ -z "${HEARTBEAT_SEC}" || "${HEARTBEAT_SEC}" -le 0 ]]; then
  HEARTBEAT_SEC=30
fi

diag_dump() {
  local reason="${1:-unknown}"
  echo "[ci-diag] reason=${reason}"
  echo "[ci-diag] timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "[ci-diag] pwd=$(pwd)"

  echo "[ci-diag] process snapshot (dune/ocaml/test):"
  ps -eo pid,ppid,etime,%cpu,%mem,comm,args \
    | grep -Ei 'dune|ocaml|alcotest|test_' \
    | grep -v grep \
    || true

  local tests_root="_build/default/test/_build/_tests"
  if [[ -d "${tests_root}" ]]; then
    echo "[ci-diag] test output files (latest 20):"
    find "${tests_root}" -type f -name "*.output" -print | tail -n 20 || true

    # Print tail of the most recent output file for quick signal.
    local last_output
    last_output="$(find "${tests_root}" -type f -name "*.output" -print | tail -n 1 || true)"
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
    echo "[ci-heartbeat] $(date -u +"%Y-%m-%dT%H:%M:%SZ") dune test still running"
    sleep "${HEARTBEAT_SEC}"
  done
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

heartbeat &
hb_pid="$!"

set +e
timeout --foreground "${TEST_TIMEOUT_SEC}" bash -lc "${TEST_CMD}"
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

echo "[ci-run] tests completed successfully"
