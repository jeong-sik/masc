#!/usr/bin/env bash
# Local SearXNG helper for the MASC-owned WebSearch backend.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE="${MASC_SEARXNG_IMAGE:-searxng/searxng:latest}"
CONTAINER="${MASC_SEARXNG_CONTAINER:-masc-searxng}"
HOST="${MASC_SEARXNG_HOST:-127.0.0.1}"
PORT="${MASC_SEARXNG_PORT:-8888}"
CONTAINER_PORT="${MASC_SEARXNG_CONTAINER_PORT:-8080}"
TIMEOUT_SEC="${MASC_SEARXNG_SMOKE_TIMEOUT_SEC:-10}"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/searxng-local.sh <start|status|smoke|logs|stop> [args]

Commands:
  start          Create settings.yml if needed and start the Docker container.
                 Needs MASC_SEARXNG_CONFIG_DIR or MASC_BASE_PATH.
  status         Print container status and probe /healthz when running.
  smoke [query]  Run a JSON search request. Defaults to "Tortoise Glass Museum".
  logs [lines]   Show recent container logs. Defaults to 80 lines.
  stop           Stop the container without removing it.

Environment:
  MASC_SEARXNG_URL          URL MASC should use. Defaults to http://127.0.0.1:8888.
  MASC_SEARXNG_CONFIG_DIR   Config directory. Defaults to $XDG_DATA_HOME/masc-searxng,
                            else $HOME/.local/share/masc-searxng. Host-global on
                            purpose: the container name and published port are
                            global, so a per-workspace directory would leave a
                            second workspace starting the first one's container.
  MASC_SEARXNG_PORT         Host port. Defaults to 8888.
  MASC_SEARXNG_CONTAINER    Container name. Defaults to masc-searxng.
  MASC_SEARXNG_IMAGE        Docker image. Defaults to searxng/searxng:latest.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

# Only `start` reads the config directory. It is host-global (XDG data
# home): the container name and published port are global, so a
# per-workspace directory would leave a second workspace starting the first
# one's container (#43181 item 6).
config_dir() {
  local named="${MASC_SEARXNG_CONFIG_DIR:-}" xdg="${XDG_DATA_HOME:-}" home="${HOME:-}"
  # A value of only spaces names nothing.
  if [ -n "${named//[[:space:]]/}" ]; then
    printf '%s\n' "$named"
  elif [ -n "${xdg//[[:space:]]/}" ]; then
    printf '%s\n' "$xdg/masc-searxng"
  elif [ -n "${home//[[:space:]]/}" ]; then
    printf '%s\n' "$home/.local/share/masc-searxng"
  else
    die "MASC_SEARXNG_CONFIG_DIR is required (no XDG_DATA_HOME or HOME to default from)"
  fi
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is required"
}

searxng_url() {
  # 127.0.0.1 and not localhost: localhost may resolve to ::1 first, where a
  # different program can answer on the same port (#43181 item 7).
  printf '%s\n' "${MASC_SEARXNG_URL:-http://127.0.0.1:$PORT}"
}

generate_secret() {
  if [ -n "${MASC_SEARXNG_SECRET_KEY:-}" ]; then
    printf '%s\n' "$MASC_SEARXNG_SECRET_KEY"
  elif command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    printf 'masc-local-searxng-%s\n' "$(date +%s)"
  fi
}

ensure_settings() {
  local settings="$CONFIG_DIR/settings.yml"
  if [ -f "$settings" ]; then
    return 0
  fi

  mkdir -p "$CONFIG_DIR"
  local secret
  secret="$(generate_secret)"
  # This body must stay byte-equal to Sandbox_prerequisites.searxng_settings
  # for the same key (a test pins it). No server.bind_address/port: the image
  # execs granian, which binds from GRANIAN_HOST/GRANIAN_PORT, and those two
  # settings only apply to a direct `python searx/webapp.py` run (#43181).
  cat >"$settings" <<EOF
use_default_settings: true

search:
  formats:
    - html
    - json

server:
  limiter: false
  secret_key: "$secret"
EOF
  echo "[searxng-local] wrote $settings" >&2
}

container_exists() {
  docker inspect "$CONTAINER" >/dev/null 2>&1
}

container_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" = "true" ]
}

cmd_start() {
  CONFIG_DIR="$(config_dir)"
  require_docker
  ensure_settings

  if container_exists; then
    if container_running; then
      echo "[searxng-local] container already running: $CONTAINER"
    else
      docker start "$CONTAINER" >/dev/null
      echo "[searxng-local] started existing container: $CONTAINER"
    fi
  else
    # Hardening measured 2026-10-17 on the pinned image: boots, /healthz
    # 200, /search answers, with both flags. The entrypoint chowns its mounts
    # (ignored noise on this read-only one) and execs granian as the same uid.
    docker run \
      --name "$CONTAINER" \
      -d \
      --restart unless-stopped \
      --cap-drop ALL \
      --security-opt no-new-privileges:true \
      -p "$HOST:$PORT:$CONTAINER_PORT" \
      -v "$CONFIG_DIR:/etc/searxng:ro" \
      "$IMAGE" >/dev/null
    echo "[searxng-local] started new container: $CONTAINER"
  fi

  echo "export MASC_SEARXNG_URL=$(searxng_url)"
  echo "[searxng-local] run: $REPO_ROOT/scripts/searxng-local.sh smoke"
}

cmd_status() {
  require_docker

  if ! container_exists; then
    echo "[searxng-local] container missing: $CONTAINER"
    exit 1
  fi

  docker ps \
    --filter "name=^/${CONTAINER}$" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

  if container_running; then
    curl -fsS --max-time "$TIMEOUT_SEC" "$(searxng_url)/healthz" >/dev/null
    echo "[searxng-local] healthz ok: $(searxng_url)"
  fi
}

cmd_smoke() {
  local query="${*:-Tortoise Glass Museum}"
  local payload
  payload="$(
    curl -fsS \
      --max-time "$TIMEOUT_SEC" \
      --get "$(searxng_url)/search" \
      --data-urlencode "q=$query" \
      --data "format=json"
  )"

  if command -v jq >/dev/null 2>&1; then
    local count
    count="$(printf '%s\n' "$payload" | jq '.results | length')"
    if [ "$count" -lt 1 ]; then
      die "search returned no results for query: $query"
    fi
    printf '%s\n' "$payload" \
      | jq -r '.results[:5][] | [.title, .url] | @tsv'
  else
    printf '%s\n' "$payload"
  fi
}

cmd_logs() {
  require_docker
  local lines="${1:-80}"
  docker logs --tail "$lines" "$CONTAINER"
}

cmd_stop() {
  require_docker
  if ! container_exists; then
    echo "[searxng-local] container missing: $CONTAINER"
    return 0
  fi
  docker stop "$CONTAINER" >/dev/null
  echo "[searxng-local] stopped: $CONTAINER"
}

case "${1:-}" in
  start)
    shift
    cmd_start "$@"
    ;;
  status)
    shift
    cmd_status "$@"
    ;;
  smoke)
    shift
    cmd_smoke "$@"
    ;;
  logs)
    shift
    cmd_logs "$@"
    ;;
  stop)
    shift
    cmd_stop "$@"
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    usage
    die "unknown command: $1"
    ;;
esac
