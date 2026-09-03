#!/usr/bin/env bash
# Static census for the Keeper runtime-setting authority.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGISTRY="$REPO_ROOT/lib/config/keeper_runtime_setting_registry.ml"
RUNTIME_CONFIG="$REPO_ROOT/lib/keeper_runtime/keeper_runtime_config.ml"
KEEPER_CONFIG="$REPO_ROOT/lib/config/env_config_keeper.ml"
SUPERVISOR_CONFIG="$REPO_ROOT/lib/config/env_config_keeper_supervisor.ml"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

for required in "$REGISTRY" "$RUNTIME_CONFIG" "$KEEPER_CONFIG" "$SUPERVISOR_CONFIG"; do
  [ -f "$required" ] || fail "missing required source: $required"
done

registry_envs="$({
  sed -n 's/.*~env_name:"\(MASC_[A-Z0-9_]*\)".*/\1/p' "$REGISTRY"
} | sort -u)"

declared_keeper_envs="$({
  grep -ho 'MASC_KEEPER_[A-Z0-9_]*' "$KEEPER_CONFIG" "$SUPERVISOR_CONFIG" || true
} | grep -v '^MASC_KEEPER_RUNTIME_PROVIDER_ALLOWLIST$' | sort -u)"

missing=0
while IFS= read -r env_name; do
  [ -n "$env_name" ] || continue
  if ! grep -qx "$env_name" <<<"$registry_envs"; then
    echo "UNREGISTERED KEEPER ENV: $env_name"
    missing=$((missing + 1))
  fi
done <<<"$declared_keeper_envs"

[ "$missing" -eq 0 ] || fail "$missing Keeper env declaration(s) lack registry rows"

# Duplicate detection covers every registered row, not just MASC_-prefixed
# ones — provider credentials (BRAVE_SEARCH_API_KEY etc.) are registered
# without the prefix and must not escape this check. The coverage check
# above stays MASC_KEEPER_-scoped by design.
duplicate_envs="$({
  sed -n 's/.*~env_name:"\([A-Z][A-Z0-9_]*\)".*/\1/p' "$REGISTRY"
} | sort | uniq -d)"
[ -z "$duplicate_envs" ] || fail "duplicate env identities: $duplicate_envs"

duplicate_toml="$({
  sed -n 's/.*~exposure:(Toml_and_env "\([^"]*\)").*/\1/p' "$REGISTRY"
} | sort | uniq -d)"
[ -z "$duplicate_toml" ] || fail "duplicate TOML identities: $duplicate_toml"

grep -q \
  'let key_to_env = Keeper_runtime_setting_registry.toml_env_mappings' \
  "$RUNTIME_CONFIG" \
  || fail "Keeper_runtime_config does not project mappings from the registry"

echo "PASS: Keeper runtime settings are registry-backed ($(
  printf '%s\n' "$declared_keeper_envs" | sed '/^$/d' | wc -l | tr -d ' '
) Keeper env declarations inventoried)."
