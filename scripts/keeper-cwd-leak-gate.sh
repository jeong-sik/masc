#!/usr/bin/env bash
# Keeper host_cwd leak gate.
#
# Rule: no `("cwd", `String cwd)` literal may appear in an Assoc list
# that also contains `("via", `String "docker")` within ±15 lines, in
# any file under lib/keeper/.
#
# Background: PR #11080 fixed the host path leak in
# keeper_status_detail.execution_context. Sibling response builders
# in keeper_shell_docker.ml and keeper_exec_shell.ml had the same
# bug class — Docker `--workdir` was translated to the in-container
# path, but the response JSON echoed the host abs path, so the LLM
# emitted `cd /Users/...` on the next turn (invalid inside the
# container). PRs #11323 / #11336 / #11349 introduced the
# `Keeper_cwd_response` audience-tagged type and wired it through
# the Docker-route response builders. This gate prevents future
# regressions of the same bug class by failing CI when the
# leak-prone literal pattern reappears near a docker-route tag.
#
# Usage:
#   scripts/keeper-cwd-leak-gate.sh         # check; exit 0 ok / 1 leak found
#
# Exit codes:
#   0  no leak detected
#   1  one or more leaks detected (file:line printed for each)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_DIR="${REPO_ROOT}/lib/keeper"
LITERAL_PATTERN='("cwd", `String cwd)'
DOCKER_PATTERN='("via", `String "docker")'
WINDOW=15

if [ ! -d "${TARGET_DIR}" ]; then
  echo "ERROR: target directory not found: ${TARGET_DIR}" >&2
  exit 1
fi

failures=0
failure_lines=""

# shellcheck disable=SC2044
for f in $(find "${TARGET_DIR}" -name '*.ml' -type f); do
  rel="${f#${REPO_ROOT}/}"
  # Find every line containing the leak literal.
  while IFS=: read -r ln content; do
    [ -z "${ln}" ] && continue
    # Compute window bounds, clamped to [1, file_lines].
    start=$(( ln > WINDOW ? ln - WINDOW : 1 ))
    end=$(( ln + WINDOW ))
    # Look for docker-route tag within the window.
    if sed -n "${start},${end}p" "${f}" | grep -F -q "${DOCKER_PATTERN}"; then
      failure_lines="${failure_lines}${rel}:${ln}: ${content}"$'\n'
      failures=$(( failures + 1 ))
    fi
  done < <(grep -nF "${LITERAL_PATTERN}" "${f}" 2>/dev/null || true)
done

if [ "${failures}" -gt 0 ]; then
  printf '%s' "${failure_lines}" >&2
  echo "" >&2
  echo "${failures} host_cwd leak(s) detected near a (\"via\", \`String \"docker\") tag." >&2
  echo "Wire the response builder through Keeper_cwd_response.to_yojson_response." >&2
  echo "Reference: lib/keeper/keeper_cwd_response.mli (PR #11323), and the wiring patterns in" >&2
  echo "  lib/keeper/keeper_shell_docker.ml (PR #11336)" >&2
  echo "  lib/keeper/keeper_exec_shell.ml (PR #11349)" >&2
  exit 1
fi

echo "OK: no host_cwd leak in ${TARGET_DIR#${REPO_ROOT}/}"
