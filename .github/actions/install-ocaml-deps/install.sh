#!/usr/bin/env bash
set -euo pipefail

log_elapsed() {
  local label="$1"
  local started_at="$2"
  local elapsed
  elapsed="$(( $(date +%s) - started_at ))"
  echo "${label} in ${elapsed}s"
}

# opam's depext step (e.g. conf-protoc -> libprotobuf-dev protobuf-compiler)
# runs apt-get install even when no OS_PACKAGES are requested. A stale runner
# image index then points at superseded .deb versions and every fetch 404s,
# so refresh the index unconditionally before any apt or opam install.
refresh_apt_index() {
  local started_at
  started_at="$(date +%s)"
  echo "Refreshing apt package index..."
  if sudo apt-get update -qq; then
    log_elapsed "Refreshed apt package index" "${started_at}"
  else
    echo \
      "::warning::apt package index refresh failed; attempting install with existing package index" \
      >&2
  fi
}

install_os_packages() {
  if [ -z "${OS_PACKAGES:-}" ]; then
    echo "No extra OS packages requested."
    return 0
  fi

  local started_at
  started_at="$(date +%s)"
  declare -a package_args=()
  read -r -a package_args <<< "${OS_PACKAGES}"
  echo "Installing OS packages: ${OS_PACKAGES}"
  sudo apt-get install -y "${package_args[@]}"
  log_elapsed "Installed OS packages" "${started_at}"
}

# A switch restored under its exact cache key was saved after the pins and
# the install of this same lock (setup-ocaml-toolchain), so opam has nothing
# to build. It still looks for each package's system packages, and a fresh
# runner has none of conf-protoc's: opam then fetches libprotobuf-dev and
# protobuf-compiler from the apt mirror on every run, and a run fails
# whenever the mirror does not answer (issue #51372). A job that only
# type-checks uses neither, so it may ask for no system packages
# (--no-depexts). The answer is "no" for a switch that was not restored
# exactly, and when the job asks for OS packages of its own.
switch_restored_complete() {
  [ "${SYSTEM_PACKAGES_ON_EXACT_RESTORE:-install}" = "skip" ] \
    && [ "${MASC_OPAM_SWITCH_EXACT_RESTORE:-}" = "true" ] \
    && [ -z "${OS_PACKAGES:-}" ]
}

# $1 names the attempt in the log lines; the rest are extra opam flags.
run_opam_install_attempt() {
  local attempt="$1"
  shift
  local started_at elapsed status opam_pid heartbeat_pid
  declare -a install_args=()

  if [ -n "${INSTALL_FLAGS:-}" ]; then
    read -r -a install_args <<< "${INSTALL_FLAGS}"
  fi
  install_args+=("$@")

  started_at="$(date +%s)"
  echo "Starting opam install attempt ${attempt} (timeout: ${INSTALL_TIMEOUT_MINUTES}m)"

  set +e
  # --locked: install what masc.opam.locked pins, not whatever the solver picks
  # today from masc.opam's lower bounds. Without it, yojson 3.0 arrived on a
  # cache miss and broke every build on main (#28327); the same door stands
  # open for the next major bump, and it opens at cache expiry rather than at
  # a commit anyone can point at (#28543). The keeper-sandbox image already
  # built from the lock, so CI and the sandbox could resolve different graphs.
  #
  # Off from #29746 to #29812 because the lock still described a 0.23.0 switch:
  # ocamlfind 1.9.8 wanted ocaml < 5.5.0~ and compiler-cloning was enabled,
  # neither of which opam can build against the pinned 5.5.0. The lock in this
  # commit is regenerated on a 5.5.0 switch, so the flag comes back with it --
  # and this install step is what proves the regenerated lock resolves.
  timeout --signal=TERM --kill-after=60s "${INSTALL_TIMEOUT_MINUTES}m" \
    opam install ./masc.opam --deps-only --locked "${install_args[@]}" --yes &
  opam_pid=$!
  (
    while kill -0 "${opam_pid}" 2>/dev/null; do
      elapsed="$(( $(date +%s) - started_at ))"
      echo "opam install attempt ${attempt} still running (${elapsed}s elapsed)"
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
    echo "opam install attempt ${attempt} succeeded in ${elapsed}s"
    return 0
  fi
  if [ "${status}" -eq 124 ]; then
    echo "opam install attempt ${attempt} timed out after ${elapsed}s"
    return 124
  fi

  echo "opam install attempt ${attempt} failed with exit ${status} after ${elapsed}s"
  return "${status}"
}

main() {
  if ! command -v timeout >/dev/null 2>&1; then
    echo "timeout command is required for CI dependency setup" >&2
    exit 1
  fi

  export OPAMCONFIRMLEVEL="${OPAMCONFIRMLEVEL:-unsafe-yes}"
  export OPAMYES="${OPAMYES:-1}"

  if switch_restored_complete; then
    echo "The switch was restored under its exact cache key; asking opam for no system packages."
    if run_opam_install_attempt "on the restored switch" --no-depexts; then
      return 0
    fi
    echo "::warning::opam install without system packages failed on the restored switch; installing them"
  fi

  refresh_apt_index
  install_os_packages

  for attempt in 1 2 3; do
    if run_opam_install_attempt "${attempt}/3"; then
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
