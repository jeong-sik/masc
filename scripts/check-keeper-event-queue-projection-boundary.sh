#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MASC_KEEPER_EVENT_QUEUE_BOUNDARY_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

fail() {
  echo "[keeper-event-queue-projection-boundary] $*" >&2
  exit 1
}

cd "${REPO_ROOT}"

facades=(
  lib/keeper/keeper_registry_event_queue.ml
  lib/keeper/keeper_registry_event_queue.mli
  lib/keeper/keeper_registry_event_queue_exact_execution.ml
  lib/keeper/keeper_registry_event_queue_exact_execution.mli
)
if rg -n --fixed-strings 'mark_transition_projected_result' "${facades[@]}"; then
  fail "raw transition retirement must not be exposed through Keeper registry facades"
fi

actual="$({
  rg -l --fixed-strings \
    'mark_transition_projected_result' \
    lib \
    --glob '*.ml' \
    --glob '*.mli' || true
} | LC_ALL=C sort)"
expected="$(printf '%s\n' \
  lib/keeper/keeper_reaction_ledger.ml \
  lib/keeper_runtime/keeper_event_queue_persistence.ml \
  lib/keeper_runtime/keeper_event_queue_persistence.mli \
  | LC_ALL=C sort)"

if [[ "${actual}" != "${expected}" ]]; then
  printf '%s\n' "expected allowlist:" "${expected}" "actual references:" "${actual}" >&2
  fail "only the canonical reaction ledger may call the low-level retirement primitive"
fi

echo "[keeper-event-queue-projection-boundary] OK"
