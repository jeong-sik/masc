#!/usr/bin/env bash
# quickstart.sh — one command to install, seed a keeper team, and open the MASC
# dashboard on macOS or Linux.
#
# It seeds the runtime config (runtime.toml / tool_policy.toml / oas-models.toml
# / prompts) BEFORE seeding a keeper team, because the server only backfills a
# config root it did not create — team-first would leave runtime.toml missing.
# The team keepers inherit [runtime].default (ollama_cloud.deepseek-v4-flash),
# so no model catalog is edited and config stays coherent with runtime.toml.
#
# Usage:
#   ./quickstart.sh                       # native build+run, classic team, open dashboard
#   ./quickstart.sh --docker              # run via docker compose instead
#   ./quickstart.sh --base-path DIR       # isolated runtime state dir (default: ~/masc-quickstart)
#   ./quickstart.sh --team PRESET         # keeper team preset (default: classic; see presets/)
#   ./quickstart.sh --port N              # HTTP port (default: 8935)
#   ./quickstart.sh --no-open             # do not open the browser
#   ./quickstart.sh --no-start            # seed only; do not start the server
#
# Env:
#   OLLAMA_CLOUD_API_KEY  Required for the default flash model. Prompted if a TTY
#                         and unset; otherwise the run aborts with instructions.
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

MODE="native"
BASE_PATH="${MASC_QUICKSTART_HOME:-$HOME/masc-quickstart}"
TEAM="classic"
PORT="8935"
OPEN_BROWSER=1
START_SERVER=1

while [ $# -gt 0 ]; do
  case "$1" in
    --docker)     MODE="docker"; shift ;;
    --native)     MODE="native"; shift ;;
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
ensure_api_key() {
  if [ -n "${OLLAMA_CLOUD_API_KEY:-}" ]; then
    log "OLLAMA_CLOUD_API_KEY found in environment (len ${#OLLAMA_CLOUD_API_KEY})"
    return 0
  fi
  if [ -t 0 ]; then
    printf '%s?%s Enter OLLAMA_CLOUD_API_KEY (from https://ollama.com/settings/keys): ' "$c_cya" "$c_off"
    stty -echo 2>/dev/null || true
    read -r OLLAMA_CLOUD_API_KEY || true
    stty echo 2>/dev/null || true
    echo
    [ -n "$OLLAMA_CLOUD_API_KEY" ] || die "no API key provided"
    export OLLAMA_CLOUD_API_KEY
  else
    die "OLLAMA_CLOUD_API_KEY is unset. Export it or run in a terminal:
      export OLLAMA_CLOUD_API_KEY=... && ./quickstart.sh"
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
  for f in runtime.toml tool_policy.toml; do
    if [ ! -e "$cfg/$f" ]; then cp "config/$f" "$cfg/$f"; log "seeded config/$f"; fi
  done
  if [ ! -e "$cfg/oas-models.toml" ]; then
    cp "oas-models.toml" "$cfg/oas-models.toml"; log "seeded oas-models.toml"
  fi
  if [ ! -d "$cfg/prompts" ] && [ -d "config/prompts" ]; then
    cp -R "config/prompts" "$cfg/prompts"; log "seeded config/prompts/"
  fi
}

write_env_local() {
  local base="$1"
  local env_file="$base/.masc/config/.env.local"
  mkdir -p "$(dirname "$env_file")"
  # Preserve any existing non-key lines; rewrite the key line idempotently.
  if [ -f "$env_file" ]; then
    grep -v '^export OLLAMA_CLOUD_API_KEY=' "$env_file" > "$env_file.tmp" 2>/dev/null || true
    mv "$env_file.tmp" "$env_file"
  fi
  printf 'export OLLAMA_CLOUD_API_KEY=%s\n' "$OLLAMA_CLOUD_API_KEY" >> "$env_file"
  chmod 600 "$env_file" 2>/dev/null || true
  log "wrote provider key to $env_file"
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
  cat <<EOF

${c_grn}MASC is up.${c_off}

  Dashboard:  ${c_cya}${DASHBOARD_URL}${c_off}
  Health:     http://127.0.0.1:${PORT}/health
  MCP:        http://127.0.0.1:${PORT}/mcp
  Team:       ${TEAM} keepers on ollama_cloud.deepseek-v4-flash
  State dir:  ${BASE_PATH}/.masc

  ${c_dim}Stop (native): kill \$(lsof -ti tcp:${PORT} -sTCP:LISTEN)
  Stop (docker): docker compose --profile oneclick down${c_off}
EOF
}

# ---- native mode -------------------------------------------------------------
run_native() {
  command -v dune >/dev/null 2>&1 || warn "dune not found; start-masc.sh will fail if no prebuilt binary exists"

  step "1/4  Seed runtime config catalogs"
  seed_catalogs "$BASE_PATH"

  step "2/4  Seed keeper team ('$TEAM')"
  bash scripts/seed-team.sh --preset "$TEAM" --base-path "$BASE_PATH"

  step "3/4  Write provider key"
  write_env_local "$BASE_PATH"

  if [ "$START_SERVER" -eq 0 ]; then
    log "seed complete; skipping server start (--no-start)"
    log "start later with: ./start-masc.sh --http --base-path '$BASE_PATH' --port $PORT"
    return 0
  fi

  step "4/4  Build + start server (this can take a while on first build)"
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
    print_success
    open_browser
  else
    warn "server did not report healthy in time; tail the log:"
    warn "  tail -n 40 '$MASC_LOG_FILE'"
    exit 1
  fi
}

# ---- docker mode -------------------------------------------------------------
run_docker() {
  command -v docker >/dev/null 2>&1 || die "docker not found; install Docker Desktop or docker engine"
  docker compose version >/dev/null 2>&1 || die "docker compose v2 not found"

  step "1/2  Build + start via docker compose (profile: oneclick)"
  log "self-contained image builds from source; first build is slow (OCaml 5.5 + deps)"
  log "OLLAMA_CLOUD_API_KEY and MASC_TEAM_PRESET=$TEAM are passed to the container"
  # Name the service explicitly so the always-on observability services (jaeger,
  # loki, victoriametrics — no `profiles:` key) are NOT pulled in; only the
  # self-contained masc-oneclick container starts.
  OLLAMA_CLOUD_API_KEY="$OLLAMA_CLOUD_API_KEY" MASC_TEAM_PRESET="$TEAM" MASC_HOST_PORT="$PORT" \
    docker compose --profile oneclick up -d --build masc-oneclick

  step "2/2  Wait for health"
  if wait_for_health "$PORT" "${MASC_QUICKSTART_HEALTH_TIMEOUT:-300}"; then
    print_success
    printf '%s  Note: the container binds a network address, so the dashboard shows its\n' "$c_dim"
    printf '  shell but its live data needs an admin token. For the zero-auth\n'
    printf '  dashboard, use the native path: ./quickstart.sh%s\n' "$c_off"
    open_browser
  else
    warn "container did not report healthy in time; inspect logs:"
    warn "  docker compose logs -f masc"
    exit 1
  fi
}

# ---- main --------------------------------------------------------------------
printf '%sMASC quickstart%s  (mode=%s, team=%s, port=%s)\n' "$c_grn" "$c_off" "$MODE" "$TEAM" "$PORT"
ensure_api_key
case "$MODE" in
  native) run_native ;;
  docker) run_docker ;;
  *) die "unknown mode: $MODE" ;;
esac
