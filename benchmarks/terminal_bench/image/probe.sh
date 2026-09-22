#!/usr/bin/env bash
# Bounded probes whose output is read as a value.
#
# A probe's stdout is the value — a version, a commit — and its stderr is
# whatever the probed program logs on the way. masc writes an MCP startup line
# to stderr on every run, so a merged stream never equals the commit
# `build-commit` prints, and fetch_masc.sh refused every release it downloaded.
# The two streams stay apart here.
#
# The packaging scripts read the same value the same way: the run() helper in
# scripts/package-macos-runtime.py passes stderr=subprocess.PIPE before comparing
# `masc build-commit` to the commit, and package-linux-runtime.py compares through
# that helper. This probe was the one place that merged the streams.
#
# Sourcing this file defines functions and sets defaults; it runs no probe, so a
# test can call the functions without a download or a container.

PROBE_TIMEOUT_SEC="${PROBE_TIMEOUT_SEC:-600}"
PROBE_STDERR_FILE="${PROBE_STDERR_FILE:-}"

# A caller with a directory of its own points the capture at a path inside it,
# so the caller's cleanup covers the file. Without this the first probe makes a
# temporary one.
probe_init() {
  PROBE_STDERR_FILE="$1"
}

run_bounded() {
  if [[ -z "${PROBE_STDERR_FILE}" ]]; then
    PROBE_STDERR_FILE="$(mktemp)"
  fi
  set +e
  # TERM gives Docker one second to clean up; KILL makes the bound hold even
  # when the CLI or daemon path ignores cancellation.
  PROBE_OUTPUT="$(timeout --kill-after=1 "${PROBE_TIMEOUT_SEC}" "$@" 2>"${PROBE_STDERR_FILE}")"
  PROBE_STATUS=$?
  PROBE_STDERR="$(<"${PROBE_STDERR_FILE}")"
  set -e
}

probe_timed_out() {
  [[ ${PROBE_STATUS} -eq 124 || ${PROBE_STATUS} -eq 137 ]]
}

# Both streams, for a message that has to explain a failure: Docker reports on
# stderr, while a refusal from the probed CLI can arrive on either one.
probe_diagnostic() {
  if [[ -n "${PROBE_OUTPUT}" && -n "${PROBE_STDERR}" ]]; then
    printf '%s\n%s' "${PROBE_OUTPUT}" "${PROBE_STDERR}"
  else
    printf '%s' "${PROBE_OUTPUT}${PROBE_STDERR}"
  fi
}
