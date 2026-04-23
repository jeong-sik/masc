#!/usr/bin/env bash
# CI gate: SSOT drift detection between Provider_adapter.spawn_key and Spawn.spawn_config_of_key.
# Meta-issue: #9516
#
# CONTRACT: Every spawn_key declared in Provider_adapter.direct_adapters must have a
# corresponding branch in Spawn.spawn_config_of_key, and vice versa.
# This prevents runtime "unknown agent" failures when an adapter is added but the
# spawn mapping is forgotten.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Extract spawn_key values from Provider_adapter.direct_adapters (Some "...")
# Filter out None entries, sort, dedupe.
adapter_keys=$(
  rg 'spawn_key\s*=\s*Some\s*"([^"]+)"' lib/provider_adapter.ml -o -r '$1' | sort -u
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
  echo "FAIL: SSOT drift — spawn_key in Provider_adapter but missing in Spawn.spawn_config_of_key:"
  echo "$only_in_adapter" | sed 's/^/  /'
  exit_code=1
fi

if [ -n "$only_in_spawn" ]; then
  echo "FAIL: SSOT drift — spawn_config_of_key branch in Spawn but no adapter.spawn_key:"
  echo "$only_in_spawn" | sed 's/^/  /'
  exit_code=1
fi

if [ "$exit_code" -eq 0 ]; then
  echo "PASS: Provider_adapter.spawn_key <-> Spawn.spawn_config_of_key are in sync."
fi

exit "$exit_code"
