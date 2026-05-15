#!/usr/bin/env bash
# CI gate: SSOT drift detection between runtime projection spawn keys and Spawn.spawn_config_of_key.
# Meta-issue: #9516
#
# CONTRACT: Every spawn key accepted by Provider_runtime_projection must have a
# corresponding branch in Spawn.spawn_config_of_key, and vice versa.
# This prevents runtime "unknown agent" failures when an adapter is added but the
# spawn mapping is forgotten.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Extract supported spawn command keys from Provider_runtime_projection.
adapter_keys=$(
  rg '^let spawn_command_keys' lib/provider_runtime_projection.ml \
  | rg '"([^"]+)"' -o -r '$1' | sort -u
)

# Extract match arms from Spawn.spawn_config_of_key
spawn_keys=$(
  sed -n '/let spawn_config_of_key/,/^let /p' lib/spawn.ml \
  | rg '^\s*\|\s*"([^"]+)"' -o -r '$1' | sort -u
)

# Compute symmetric difference
only_in_adapter=$(comm -23 <(echo "$adapter_keys") <(echo "$spawn_keys"))
only_in_spawn=$(comm -13 <(echo "$adapter_keys") <(echo "$spawn_keys"))

exit_code=0

if [ -n "$only_in_adapter" ]; then
  echo "FAIL: SSOT drift — runtime projection spawn key missing in Spawn.spawn_config_of_key:"
  echo "$only_in_adapter" | sed 's/^/  /'
  exit_code=1
fi

if [ -n "$only_in_spawn" ]; then
  echo "FAIL: SSOT drift — spawn_config_of_key branch has no runtime projection spawn key:"
  echo "$only_in_spawn" | sed 's/^/  /'
  exit_code=1
fi

if [ "$exit_code" -eq 0 ]; then
  echo "PASS: Provider_runtime_projection spawn keys <-> Spawn.spawn_config_of_key are in sync."
fi

exit "$exit_code"
