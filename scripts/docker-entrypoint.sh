#!/usr/bin/env bash
# docker-entrypoint.sh — seed a coherent runtime config + keeper team into the
# container's writable state volume, then exec the MASC server.
#
# The image bakes immutable seed sources at /app/config-seed (catalogs, prompts)
# and /app/presets (team overlays). This entrypoint copies them into the live
# config root on the /app/.masc volume in the same catalog-first order the native
# quickstart uses, so the server boots the requested team on the default flash
# model. Idempotent: existing operator edits on the volume are preserved.
set -euo pipefail

BASE_PATH="${MASC_BASE_PATH:-/app}"
CONFIG_DIR="$BASE_PATH/.masc/config"
SEED_DIR="/app/config-seed"
TEAM="${MASC_TEAM_PRESET:-classic}"

log() { printf '[entrypoint] %s\n' "$*" >&2; }

mkdir -p "$CONFIG_DIR"

# 1. Catalogs first (runtime.toml must exist before the team is seeded, and the
#    server only backfills a config root it did not create).
for f in runtime.toml tool_policy.toml oas-models.toml; do
  if [ -f "$SEED_DIR/$f" ] && [ ! -e "$CONFIG_DIR/$f" ]; then
    cp "$SEED_DIR/$f" "$CONFIG_DIR/$f"; log "seeded $f"
  fi
done
if [ -d "$SEED_DIR/prompts" ] && [ ! -d "$CONFIG_DIR/prompts" ]; then
  cp -R "$SEED_DIR/prompts" "$CONFIG_DIR/prompts"; log "seeded prompts/"
fi

# 2. Keeper team overlay (skip when empty / "none").
if [ -n "$TEAM" ] && [ "$TEAM" != "none" ]; then
  if MASC_PRESETS_ROOT=/app/presets bash /app/scripts/seed-team.sh \
      --preset "$TEAM" --base-path "$BASE_PATH"; then
    log "seeded team preset: $TEAM"
  else
    log "team preset '$TEAM' not seeded (see message above); continuing"
  fi
fi

# 3. Provider key sanity (non-fatal: the server also reports this on /health).
if [ -z "${OLLAMA_CLOUD_API_KEY:-}" ]; then
  log "warning: OLLAMA_CLOUD_API_KEY is unset; the default flash model will not authenticate"
fi

# 4. Hand off to the server. MASC_CONFIG_DIR stays unset so config resolves to
#    $BASE_PATH/.masc/config (Local_masc), the root we just seeded.
#
# Bind host is configurable (default 0.0.0.0 for bridge networking + published
# port). The dashboard's zero-auth loopback dev-token is only served on a
# loopback bind — a deliberate boundary so an admin token never auto-exposes on
# a public bind. Consequences:
#   - Bridge (default): the dashboard shell serves, but its live data needs an
#     admin token. Open /dashboard and paste the token into the dashboard auth
#     control; authenticated requests send it only in the Authorization header.
#     For the zero-auth dashboard, use the native quickstart (./quickstart.sh),
#     which binds loopback.
#   - Linux host networking: `--network host` + MASC_BIND_HOST=127.0.0.1 makes the
#     container loopback the host loopback, enabling the zero-auth dashboard.
#     Docker Desktop (macOS/Windows) does not route host networking to the host
#     loopback, so this only helps on native Linux.
BIND_HOST="${MASC_BIND_HOST:-0.0.0.0}"
log "starting masc on ${BIND_HOST}:${PORT:-8080} (base-path=$BASE_PATH, team=$TEAM)"
exec /app/masc --host="$BIND_HOST" --port="${PORT:-8080}" --base-path="$BASE_PATH"
