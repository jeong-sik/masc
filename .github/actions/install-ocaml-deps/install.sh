#!/usr/bin/env bash
set -euo pipefail

log_elapsed() {
  local label="$1"
  local started_at="$2"
  local elapsed
  elapsed="$(( $(date +%s) - started_at ))"
  echo "${label} in ${elapsed}s"
}

install_os_packages() {
  if [ -z "${OS_PACKAGES:-}" ]; then
    echo "No extra OS packages requested."
    return 0
  fi

  local started_at
  started_at="$(date +%s)"
  echo "Refreshing apt package index..."
  sudo apt-get update -qq
  log_elapsed "Refreshed apt package index" "${started_at}"

  started_at="$(date +%s)"
  declare -a package_args=()
  read -r -a package_args <<< "${OS_PACKAGES}"
  echo "Installing OS packages: ${OS_PACKAGES}"
  sudo apt-get install -y "${package_args[@]}"
  log_elapsed "Installed OS packages" "${started_at}"
}

run_opam_install_attempt() {
  local attempt="$1"
  local started_at elapsed status opam_pid heartbeat_pid
  declare -a install_args=()

  if [ -n "${INSTALL_FLAGS:-}" ]; then
    read -r -a install_args <<< "${INSTALL_FLAGS}"
  fi

  started_at="$(date +%s)"
  echo "Starting opam install attempt ${attempt}/3 (timeout: ${INSTALL_TIMEOUT_MINUTES}m)"

  set +e
  timeout --signal=TERM --kill-after=60s "${INSTALL_TIMEOUT_MINUTES}m" \
    opam install . --deps-only "${install_args[@]}" --yes &
  opam_pid=$!
  (
    while kill -0 "${opam_pid}" 2>/dev/null; do
      elapsed="$(( $(date +%s) - started_at ))"
      echo "opam install attempt ${attempt}/3 still running (${elapsed}s elapsed)"
      sleep "${HEARTBEAT_SECONDS}"
    done
  ) &
  heartbeat_pid=$!
  wait "${opam_pid}"
  status=$?
  set -e

  kill "${heartbeat_pid}" 2>/dev/null || true
  wait "${heartbeat_pid}" 2>/dev/null || true

  elapsed="$(( $(date +%s) - started_at ))"
  if [ "${status}" -eq 0 ]; then
    echo "opam install attempt ${attempt}/3 succeeded in ${elapsed}s"
    return 0
  fi
  if [ "${status}" -eq 124 ]; then
    echo "opam install attempt ${attempt}/3 timed out after ${elapsed}s"
    return 124
  fi

  echo "opam install attempt ${attempt}/3 failed with exit ${status} after ${elapsed}s"
  return "${status}"
}

main() {
  if ! command -v timeout >/dev/null 2>&1; then
    echo "timeout command is required for CI dependency setup" >&2
    exit 1
  fi

  export OPAMCONFIRMLEVEL="${OPAMCONFIRMLEVEL:-unsafe-yes}"
  export OPAMYES="${OPAMYES:-1}"

  install_os_packages

  for attempt in 1 2 3; do
    if run_opam_install_attempt "${attempt}"; then
      return 0
    fi

    if [ "${attempt}" -eq 3 ]; then
      echo "opam install failed after ${attempt} attempts" >&2
      return 1
    fi

    echo "Retrying opam install in 15s..."
    sleep 15
  done
}

main "$@"
