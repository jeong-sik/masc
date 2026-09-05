#!/usr/bin/env bash
# quickstart.sh — seed a local workspace, start MASC, and prepare an MCP client
# bearer on macOS or Linux.
#
# It seeds the runtime config (runtime.toml / agent-core-models-overlay.toml
# / prompts) BEFORE seeding a keeper team, because the server only backfills a
# config root it did not create — team-first would leave runtime.toml missing.
# An optional team inherits [runtime].default, so no model catalog is edited
# and config stays coherent with runtime.toml.
#
# Usage:
#   ./quickstart.sh                       # build+run workspace server, open dashboard
#   ./quickstart.sh --base-path DIR       # isolated runtime state dir (default: ~/masc-quickstart)
#   ./quickstart.sh --team PRESET         # optional Keeper preset (for example: classic)
#   ./quickstart.sh --port N              # HTTP port (default: 8935)
#   ./quickstart.sh --no-open             # do not open the browser
#   ./quickstart.sh --no-start            # seed only; do not start the server
#
# Env:
#   OLLAMA_CLOUD_API_KEY  Read from your shell when a seeded Keeper needs it.
#                         Never prompted for, and never written to disk.
#   MASC_QUICKSTART_HOME  Default base path when --base-path is omitted.

set -euo pipefail

c_grn=$(printf '\033[32m'); c_yel=$(printf '\033[33m'); c_red=$(printf '\033[31m')
c_cya=$(printf '\033[36m'); c_dim=$(printf '\033[2m'); c_off=$(printf '\033[0m')
[ -t 1 ] || { c_grn=""; c_yel=""; c_red=""; c_cya=""; c_dim=""; c_off=""; }
log()  { printf '%s==>%s %s\n' "$c_grn" "$c_off" "$*"; }
step() { printf '\n%s## %s%s\n' "$c_cya" "$*" "$c_off"; }
warn() { printf '%swarn:%s %s\n' "$c_yel" "$c_off" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BASE_PATH="${MASC_QUICKSTART_HOME:-$HOME/masc-quickstart}"
TEAM="none"
PORT="8935"
OPEN_BROWSER=1
START_SERVER=1

while [ $# -gt 0 ]; do
  case "$1" in
    --base-path)  BASE_PATH="${2:?}"; shift 2 ;;
    --team)       TEAM="${2:?}"; shift 2 ;;
    --port)       PORT="${2:?}"; shift 2 ;;
    --no-open)    OPEN_BROWSER=0; shift ;;
    --no-start)   START_SERVER=0; shift ;;
    -h|--help)    grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

DASHBOARD_URL="http://127.0.0.1:${PORT}/dashboard"

# ---- provider key ------------------------------------------------------------
# There is no prompt and no file. A provider key is read from the environment
# the server is started in, which is the one place the running server looks --
# writing a copy to .masc/config/.env.local only created a second source of
# truth that had to be kept in step and chmod'd by hand.
report_api_key() {
  if [ -n "${OLLAMA_CLOUD_API_KEY:-}" ]; then
    log "OLLAMA_CLOUD_API_KEY found in environment (len ${#OLLAMA_CLOUD_API_KEY})"
  else
    log "OLLAMA_CLOUD_API_KEY is unset; a seeded Keeper on the default flash"
    log "  model will have no runtime until you export it and restart the server"
  fi
}

# ---- seed config + team (native) ---------------------------------------------
seed_catalogs() {
  local base="$1"
  local cfg="$base/.masc/config"
  mkdir -p "$cfg"
  # Copy-if-missing so re-runs never clobber operator edits. Order matters:
  # these catalogs must exist before the team is seeded (see file header).
  local f
  for f in runtime.toml agent-core-models-overlay.toml; do
    if [ ! -e "$cfg/$f" ]; then cp "config/$f" "$cfg/$f"; log "seeded config/$f"; fi
  done
  if [ ! -d "$cfg/prompts" ] && [ -d "config/prompts" ]; then
    cp -R "config/prompts" "$cfg/prompts"; log "seeded config/prompts/"
  fi
}

write_mcp_client_env() {
  local env_file="$BASE_PATH/.masc/config/mcp-client.env"
  local tmp_file="$env_file.tmp.$$"
  local login_log="$BASE_PATH/.masc/quickstart-login.log"
  local exe="$SCRIPT_DIR/_build/default/bin/main_eio.exe"

  [ -x "$exe" ] || die "built MASC binary not found at $exe"
  mkdir -p "$(dirname "$env_file")"
  if ! (umask 077; MASC_BASE_PATH="$BASE_PATH" MASC_BASE_PATH_INPUT="$BASE_PATH" \
    "$exe" login \
      --base-path "$BASE_PATH" \
      --host 127.0.0.1 \
      --port "$PORT" \
      --agent quickstart-mcp-client \
      --role worker \
      --client-env MASC_TOKEN \
      --no-expiry \
      --shell >"$tmp_file") 2>"$login_log"; then
    rm -f "$tmp_file"
    warn "could not mint the MCP client bearer; inspect $login_log"
    return 1
  fi
  mv "$tmp_file" "$env_file"
  chmod 600 "$env_file"
  log "wrote MCP client exports to $env_file"
}

# ---- health wait -------------------------------------------------------------
wait_for_health() {
  local port="$1" max="${2:-60}" waited=0
  while [ "$waited" -lt "$max" ]; do
    if curl -fsS --max-time 2 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1; waited=$((waited + 1))
    printf '%s   waiting for server health... (%ds/%ds)%s\r' "$c_dim" "$waited" "$max" "$c_off" >&2
  done
  echo >&2
  return 1
}

open_browser() {
  [ "$OPEN_BROWSER" -eq 1 ] || return 0
  if command -v open >/dev/null 2>&1; then open "$DASHBOARD_URL" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$DASHBOARD_URL" >/dev/null 2>&1 || true
  fi
}

print_success() {
  local team_summary="none (workspace server only)"
  if [ "$TEAM" != "none" ]; then
    team_summary="$TEAM keepers on the configured default runtime"
  fi
  cat <<EOF

${c_grn}MASC is up.${c_off}

  Dashboard:  ${c_cya}${DASHBOARD_URL}${c_off}
  Health:     http://127.0.0.1:${PORT}/health
  MCP:        http://127.0.0.1:${PORT}/mcp
  Keepers:    ${team_summary}
  State dir:  ${BASE_PATH}/.masc
  MCP auth:   source "${BASE_PATH}/.masc/config/mcp-client.env"

  ${c_dim}Stop (native): kill \$(lsof -ti tcp:${PORT} -sTCP:LISTEN)
  Client setup: docs/MCP-TEMPLATE.md${c_off}
EOF
}

# ---- run ---------------------------------------------------------------------
run_quickstart() {
  command -v dune >/dev/null 2>&1 || warn "dune not found; start-masc.sh will fail if no prebuilt binary exists"

  step "Seed runtime config catalogs"
  seed_catalogs "$BASE_PATH"

  if [ "$TEAM" != "none" ]; then
    report_api_key
    step "Seed Keeper team ('$TEAM')"
    bash scripts/seed-team.sh --preset "$TEAM" --base-path "$BASE_PATH"
  else
    log "no Keeper preset requested"
  fi

  if [ "$START_SERVER" -eq 0 ]; then
    log "seed complete; skipping server start (--no-start)"
    if [ "$TEAM" != "none" ]; then
      log "start later with: ./start-masc.sh --http --base-path '$BASE_PATH' --port $PORT"
    else
      log "start later with: ./start-masc.sh --http --base-path '$BASE_PATH' --port $PORT"
    fi
    return 0
  fi

  step "Build + start server (this can take a while on first build)"
  MASC_LOG_FILE="$BASE_PATH/.masc/quickstart-server.log"
  export MASC_LOG_FILE
  # start-masc.sh builds main_eio.exe if missing, seeds nothing over our config
  # root (it already exists), and serves the SPA + MCP on $PORT.
  ( ./start-masc.sh --http --base-path "$BASE_PATH" --port "$PORT" ) &
  SERVER_PID=$!
  # Detach so the server keeps running after quickstart returns.
  disown "$SERVER_PID" 2>/dev/null || true
  log "server starting (pid $SERVER_PID, log: $MASC_LOG_FILE)"

  if wait_for_health "$PORT" "${MASC_QUICKSTART_HEALTH_TIMEOUT:-180}"; then
    write_mcp_client_env
    print_success
    open_browser
  else
    warn "server did not report healthy in time; tail the log:"
    warn "  tail -n 40 '$MASC_LOG_FILE'"
    exit 1
  fi
}

# ---- main --------------------------------------------------------------------
printf '%sMASC quickstart%s  (team=%s, port=%s)\n' "$c_grn" "$c_off" "$TEAM" "$PORT"
run_quickstart
