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

checkpoint_surface_files=(
  lib/keeper/keeper_checkpoint_store.ml
  lib/keeper/keeper_checkpoint_store.mli
  lib/keeper/keeper_context_core.ml
  lib/keeper/keeper_context_core.mli
  lib/keeper/keeper_context_runtime.ml
  lib/keeper/keeper_context_runtime.mli
  lib/keeper/keeper_post_turn.ml
  lib/keeper/keeper_post_turn.mli
  lib/keeper/keeper_manual_compaction.ml
  lib/keeper/keeper_manual_compaction.mli
  lib/keeper/keeper_heartbeat_loop.ml
  lib/keeper/keeper_heartbeat_loop_cycle.ml
  lib/keeper/keeper_heartbeat_loop_cycle.mli
  lib/keeper/keeper_tool_surface.ml
)
if matches="$(
  rg -n \
    'Outcome_unknown' \
    "${checkpoint_surface_files[@]}" test proto || true
)"; then
  if [[ -n "${matches}" ]]; then
    echo "[checkpoint-installation-legacy-purge] forbidden checkpoint outcome residue:" >&2
    echo "${matches}" >&2
    exit 1
  fi
fi

echo "[checkpoint-installation-legacy-purge] OK"
