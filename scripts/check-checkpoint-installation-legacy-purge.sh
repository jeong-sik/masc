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

if matches="$(
  rg -n \
    'checkpoint_commit_hint|Hint_not_emitted|Hint_delivered|Hint_failed|admitted_result|run_admitted_with_install_observer' \
    "${roots[@]}" || true
)"; then
  if [[ -n "${matches}" ]]; then
    echo "[checkpoint-installation-legacy-purge] forbidden manual-compaction legacy surface:" >&2
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
  lib/keeper/keeper_heartbeat_loop.ml
  lib/keeper/keeper_heartbeat_loop_cycle.ml
  lib/keeper/keeper_heartbeat_loop_cycle.mli
  lib/keeper/keeper_tool_surface.ml
)
if matches="$(
  # Bare constructors are meaningful only within their owning surfaces.
  # Lane_addon_action has its own live Outcome_unknown state; scanning every
  # test for that spelling confuses it with the retired checkpoint outcome.
  rg -n 'Outcome_unknown' "${checkpoint_surface_files[@]}" || true
  rg -n 'Outcome_unknown' \
    --glob '*checkpoint*' --glob '*keeper_context*' \
    --glob '*keeper_post_turn*' --glob '*keeper_heartbeat*' \
    --glob '*keeper_tool_surface*' test proto || true
  # Qualified checkpoint references remain forbidden in any caller, including
  # tests whose names belong to a different feature.
  rg -n 'Keeper_(checkpoint_store|context_core|context_runtime|post_turn|heartbeat_loop(_cycle)?|tool_surface)\.Outcome_unknown' \
    lib bin test proto || true
)"; then
  if [[ -n "${matches}" ]]; then
    echo "[checkpoint-installation-legacy-purge] forbidden checkpoint outcome residue:" >&2
    echo "${matches}" >&2
    exit 1
  fi
fi

# This block named lib/keeper/keeper_manual_compaction.{ml,mli}, which #31623
# deleted along with the compaction concept, so it scanned nothing and passed.
# The symbol is what the purge is about, and it now has no home module to come
# back to, so ask the tree instead of a file list.
if matches="$(
  rg -n \
    'on_checkpoint_installed' \
    lib bin test proto || true
)"; then
  if [[ -n "${matches}" ]]; then
    echo "[checkpoint-installation-legacy-purge] forbidden manual-compaction callback residue:" >&2
    echo "${matches}" >&2
    exit 1
  fi
fi

echo "[checkpoint-installation-legacy-purge] OK"
