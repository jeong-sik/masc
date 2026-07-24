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

canonical_source=lib/keeper/keeper_reaction_ledger.ml
qualified_call='Keeper_event_queue_persistence.mark_transition_projected_result'
qualified_call_count="$({
  rg -o --fixed-strings "${qualified_call}" "${canonical_source}" || true
} | wc -l | tr -d '[:space:]')"
if [[ "${qualified_call_count}" != "1" ]]; then
  fail "canonical reaction ledger must contain exactly one qualified retirement call"
fi

persistence_source=lib/keeper_runtime/keeper_event_queue_persistence.ml
persistence_interface=lib/keeper_runtime/keeper_event_queue_persistence.mli
for expected_single_reference in "${persistence_source}" "${persistence_interface}"; do
  reference_count="$({
    rg -o --fixed-strings 'mark_transition_projected_result' \
      "${expected_single_reference}" || true
  } | wc -l | tr -d '[:space:]')"
  if [[ "${reference_count}" != "1" ]]; then
    fail "${expected_single_reference} must contain exactly one retirement definition/declaration"
  fi
done

projector_symbol='project_event_queue_transition_outbox_result'
projector_actual="$({
  rg -l --fixed-strings \
    "${projector_symbol}" \
    lib \
    --glob '*.ml' \
    --glob '*.mli' || true
} | LC_ALL=C sort)"
projector_expected="$(printf '%s\n' \
  lib/keeper/keeper_event_queue_recovery.ml \
  lib/keeper/keeper_reaction_ledger.ml \
  lib/keeper/keeper_reaction_ledger.mli \
  | LC_ALL=C sort)"
if [[ "${projector_actual}" != "${projector_expected}" ]]; then
  printf '%s\n' \
    "expected canonical projector references:" \
    "${projector_expected}" \
    "actual references:" \
    "${projector_actual}" >&2
  fail "production callers must enter the canonical ledger projector through recovery"
fi

recovery_projector_call_count="$({
  rg -o --fixed-strings \
    "Keeper_reaction_ledger.${projector_symbol}" \
    lib/keeper/keeper_event_queue_recovery.ml || true
} | wc -l | tr -d '[:space:]')"
if [[ "${recovery_projector_call_count}" != "1" ]]; then
  fail "recovery must contain exactly one qualified canonical ledger projector call"
fi

if ! rg \
  --quiet \
  --multiline \
  --multiline-dotall \
  'let\* \(\) =\s+append_event_queue_transition_outbox_result.*?let\* \(\) = after_ledger_append \(\) in\s+Keeper_event_queue_persistence\.mark_transition_projected_result' \
  "${canonical_source}"
then
  fail "canonical projection must append, pass the post-append seam, then retire"
fi

echo "[keeper-event-queue-projection-boundary] OK"
