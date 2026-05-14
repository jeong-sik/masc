#!/usr/bin/env bash
# CI gate: Spawn must stay catalog-driven.
# Meta-issue: #9516
#
# CONTRACT: local agent process wiring lives in config/cascade.toml under
# providers.<id>.spawn and is loaded by Local_mcp_client_catalog. Spawn must not
# reintroduce a second provider-name switch or Provider_adapter spawn-key map.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

exit_code=0

require_match() {
  local description="$1"
  local pattern="$2"
  local file="$3"
  if ! rg -q "$pattern" "$file"; then
    echo "FAIL: ${description}" >&2
    echo "  missing pattern: ${pattern}" >&2
    echo "  file: ${file}" >&2
    exit_code=1
  fi
}

reject_match() {
  local description="$1"
  local pattern="$2"
  local file="$3"
  if rg -q "$pattern" "$file"; then
    echo "FAIL: ${description}" >&2
    rg -n "$pattern" "$file" >&2 || true
    exit_code=1
  fi
}

require_match \
  "Spawn.get_config must resolve through Local_mcp_client_catalog.find_spawn" \
  'Local_mcp_client_catalog\.find_spawn' \
  lib/spawn.ml

require_match \
  "Local_mcp_client_catalog must read provider spawn tables from cascade.toml" \
  '"spawn"' \
  lib/local_mcp_client_catalog.ml

require_match \
  "config/cascade.toml must declare at least one provider spawn table" \
  '^\[providers\.[^]]+\.spawn\]$' \
  config/cascade.toml

reject_match \
  "legacy provider spawn-key field must not return" \
  'spawn[_-]key' \
  lib/provider_adapter.ml

reject_match \
  "legacy Spawn.spawn_config_of_key switch must not return" \
  'spawn_config_of_key' \
  lib/spawn.ml

reject_match \
  "Spawn must not branch on hardcoded local agent labels" \
  '^\s*\|\s*"(claude|gemini|codex|kimi|glm|llama)"' \
  lib/spawn.ml

if [ "$exit_code" -eq 0 ]; then
  echo "PASS: Spawn is catalog-driven by config/cascade.toml."
fi

exit "$exit_code"
