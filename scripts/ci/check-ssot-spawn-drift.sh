#!/usr/bin/env bash
# CI gate: SSOT drift detection between Spawn_runtime_overlay and Spawn.spawn_config_of_key.
# Meta-issue: #9516
#
# CONTRACT: Every spawn_key declared in Spawn_runtime_overlay.bindings must have a
# corresponding branch in Spawn.spawn_config_of_key, and vice versa.
# This prevents runtime "unknown agent" failures when an adapter is added but the
# spawn mapping is forgotten.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Extract spawn_key values from Spawn_runtime_overlay.bindings.
overlay_keys=$(
  rg 'spawn_key\s*=\s*"([^"]+)"' lib/spawn_runtime_overlay.ml -o -r '$1' | sort -u
)

# Extract match arms from Spawn.spawn_config_of_key
spawn_keys=$(
  sed -n '/let spawn_config_of_key/,/^let /p' lib/spawn.ml \
  | rg '^\s*\|\s*"([^"]+)"' -o -r '$1' | sort -u
)

# Compute symmetric difference
only_in_overlay=$(comm -23 <(echo "$overlay_keys") <(echo "$spawn_keys"))
only_in_spawn=$(comm -13 <(echo "$overlay_keys") <(echo "$spawn_keys"))

exit_code=0

if [ -n "$only_in_overlay" ]; then
  echo "FAIL: SSOT drift — spawn_key in Spawn_runtime_overlay but missing in Spawn.spawn_config_of_key:"
  echo "$only_in_overlay" | sed 's/^/  /'
  exit_code=1
fi

if [ -n "$only_in_spawn" ]; then
  echo "FAIL: SSOT drift — spawn_config_of_key branch in Spawn but no Spawn_runtime_overlay binding:"
  echo "$only_in_spawn" | sed 's/^/  /'
  exit_code=1
fi

if [ "$exit_code" -eq 0 ]; then
  echo "PASS: Spawn_runtime_overlay.spawn_key <-> Spawn.spawn_config_of_key are in sync."
fi

exit "$exit_code"
