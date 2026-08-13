#!/usr/bin/env bash
# masc#28502. The focused-tests step exited 1 while every group in its log
# reported success, so the only way to find the failing group was to re-run the
# suites by hand. These assert the announcement exists, because a diagnostic
# that is only checked by reading the source is a diagnostic that silently
# stops working.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
script="${repo_root}/scripts/ci-run-focused-tests.sh"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# Sourcing gives the definitions without the driver. Run in a subshell because
# the script cds to the repo root.
run_case() (
  # shellcheck source=scripts/ci-run-focused-tests.sh
  . "${script}"
  "$@"
)

# --- a failing group is named where a reader will see it ---

output="$(run_case record_group_failure normal 2 2>&1)" || true
case "${output}" in
  *"::error::focused tests: normal failed (exit 2)"*) ;;
  *) fail "a failing group must be announced by name; got: ${output}" ;;
esac

# --- the announcement is outside the collapsed group ---
#
# An annotation written between ::group:: and ::endgroup:: is only visible to
# someone who already knows to expand it, which is the state this fixes. The
# helper itself must therefore emit no group markers.
case "${output}" in
  *"::group::"*) fail "the failure announcement must not open a collapsed group" ;;
  *) ;;
esac

# --- the failure is recorded, not just printed ---
#
# Two groups run inside subshells, and a subshell cannot append to its parent's
# array. The file is what makes the end-of-run summary possible at all, so an
# implementation that only echoed would pass the first assertion and still lose
# the summary.
recorded="$(
  # shellcheck source=scripts/ci-run-focused-tests.sh
  . "${script}"
  record_group_failure sse 3 >/dev/null 2>&1
  ( record_group_failure operator-control 4 >/dev/null 2>&1 )
  cat "${failed_groups_file}"
)"
case "${recorded}" in
  *"sse (exit 3)"*) ;;
  *) fail "a direct failure must be recorded; got: ${recorded}" ;;
esac
case "${recorded}" in
  *"operator-control (exit 4)"*) ;;
  *) fail "a failure inside a subshell must survive to the parent; got: ${recorded}" ;;
esac

# --- the temp file outlives a subshell ---
#
# bash resets the EXIT trap in ( ) subshells, so the parent's cleanup does not
# fire early. Asserted rather than assumed: if that ever changed, every
# subshell group's failure would vanish and the step would go back to exiting 1
# with an empty summary.
survived="$(
  # shellcheck source=scripts/ci-run-focused-tests.sh
  . "${script}"
  ( : )
  if [ -f "${failed_groups_file}" ]; then echo present; fi
)"
[ "${survived}" = "present" ] \
  || fail "the record file must survive a subshell exiting"

echo "ok: focused-tests failures are named, recorded, and survive subshells"
