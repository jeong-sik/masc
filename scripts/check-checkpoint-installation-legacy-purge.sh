#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

roots=(lib test proto docs .github)
if matches="$(
  rg -n \
    'Transaction_outcome_unknown|checkpoint_applied' \
    "${roots[@]}" || true
)"; then
  if [[ -n "${matches}" ]]; then
    echo "[checkpoint-installation-legacy-purge] forbidden legacy surface:" >&2
    echo "${matches}" >&2
    exit 1
  fi
fi

echo "[checkpoint-installation-legacy-purge] OK"
