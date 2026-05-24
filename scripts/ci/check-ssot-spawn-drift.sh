#!/usr/bin/env bash
# CI gate: old CLI Spawn integration must stay deleted.
# Meta-issue: #9516
#
# CONTRACT: masc-mcp no longer owns a provider-specific CLI spawn mapping.
# Provider execution belongs to OAS/runtime bindings and MASC model cascades.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

exit_code=0

if [ -e lib/spawn.ml ] || [ -e lib/spawn.mli ]; then
  echo "FAIL: legacy lib/spawn.* still exists:"
  ls lib/spawn.ml lib/spawn.mli 2>/dev/null | sed 's/^/  /'
  exit_code=1
fi

legacy_mapping_refs=$(
  rg -n 'spawn_config_of_key|spawn_command_keys|spawn_key_of_binding|spawn_key_of_label|legacy_local_spawn_prefix|explicit_local_model_label_result|label_is_legacy_local_spawn|LLAMA_DEFAULT_MODEL|llama\.cpp|llamacpp' \
    lib/provider_runtime_projection.ml 2>/dev/null || true
)

legacy_spawn_refs=$(
  rg -n 'spawn_config_of_key|spawn_command_keys|spawn_key_of_binding|spawn_key_of_label' \
    lib 2>/dev/null || true
)

legacy_refs="${legacy_mapping_refs}${legacy_spawn_refs}"

if [ -n "$legacy_refs" ]; then
  echo "FAIL: legacy CLI Spawn mapping reference(s) remain:"
  echo "$legacy_refs" | sed 's/^/  /'
  exit_code=1
fi

if [ "$exit_code" -eq 0 ]; then
  echo "PASS: legacy CLI Spawn mapping is removed."
fi

exit "$exit_code"
