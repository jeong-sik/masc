#!/usr/bin/env bash
# launchd/masc-mcp-start.sh
#
# RFC-0101 §2 Phase G — launchd entry point for masc-mcp.
#
# Responsibilities:
#   1. Define + invoke `sb_raise_nofile_limit` (RFC-0101 §2 missing function).
#      Raises per-process soft `nofile` rlimit to 10240 before main_eio.exe runs.
#      `Fd_accountant.fd_snapshot` (RFC-0101 §3.5) consumes the resulting
#      rlimit at startup and logs:
#        fd-accountant: rlimit_nofile soft=10240 hard=10240 (launchd raise: success/fail)
#   2. Exec the OCaml main entry, forwarding argv.
#
# Invoked by:
#   launchd/com.masc.mcp.plist  (ProgramArguments)
#
# Manual invocation (smoke test):
#   ./launchd/masc-mcp-start.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# RFC-0101 §2 cap. See docs/rfc/RFC-0101-fd-accountant-generic-pool.md §3.5.
readonly MASC_NOFILE_TARGET=10240

# RFC-0101 §2 — referenced by name in RFC body line 46:
#   "Raising kern.maxfiles ... handled in launchd/masc-mcp-start.sh's
#    sb_raise_nofile_limit. This RFC adds startup observability ..."
#
# Returns 0 on success (limit raised to >= target), non-zero on failure.
# Logs both outcomes to stderr so launchd captures them in StandardErrorPath
# and the operator can grep `(launchd raise: ...)` from there to cross-check
# what Fd_accountant.fd_snapshot reports.
sb_raise_nofile_limit() {
  local target="${1:-${MASC_NOFILE_TARGET}}"
  local before
  before="$(ulimit -n)"

  # Try to raise. macOS launchd has already applied SoftResourceLimits from
  # the plist before this script runs, so this `ulimit -n` is a belt-and-
  # suspenders raise for the case where the script is invoked manually
  # (outside launchd) or the plist was edited.
  if ulimit -n "${target}" 2>/dev/null; then
    local after
    after="$(ulimit -n)"
    echo "sb_raise_nofile_limit: raised nofile ${before} -> ${after} (target=${target}) (launchd raise: success)" >&2
    return 0
  else
    echo "sb_raise_nofile_limit: FAILED to raise nofile (current=${before}, target=${target}) (launchd raise: fail)" >&2
    return 1
  fi
}

# Best-effort raise. Don't abort startup if the raise fails — Fd_accountant
# will detect and log the gap so the operator can see it on /metrics.
sb_raise_nofile_limit "${MASC_NOFILE_TARGET}" || true

# Locate the built binary. Prefer the dune `_build/default` path; fall back to
# `dune exec` only when the binary is missing (dev convenience).
BIN="${REPO_ROOT}/_build/default/bin/main_eio.exe"

if [[ -x "${BIN}" ]]; then
  cd "${REPO_ROOT}"
  exec "${BIN}" "$@"
else
  echo "masc-mcp-start.sh: ${BIN} not found, falling back to 'dune exec'" >&2
  cd "${REPO_ROOT}"
  exec dune exec --root . bin/main_eio.exe -- "$@"
fi
