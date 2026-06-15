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
BASE_PATH="${MASC_BASE_PATH:-$HOME/me}"
CONFIG_DIR="${MASC_SEARXNG_CONFIG_DIR:-$BASE_PATH/.local/share/masc-searxng}"
TIMEOUT_SEC="${MASC_SEARXNG_SMOKE_TIMEOUT_SEC:-10}"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/searxng-local.sh <start|status|smoke|logs|stop> [args]

Commands:
  start          Create settings.yml if needed and start the Docker container.
  status         Print container status and probe /healthz when running.
  smoke [query]  Run a JSON search request. Defaults to "Tortoise Glass Museum".
  logs [lines]   Show recent container logs. Defaults to 80 lines.
  stop           Stop the container without removing it.

Environment:
  MASC_SEARXNG_URL          URL MASC should use. Defaults to http://localhost:8888.
  MASC_SEARXNG_CONFIG_DIR   Config directory. Defaults to $MASC_BASE_PATH/.local/share/masc-searxng.
  MASC_SEARXNG_PORT         Host port. Defaults to 8888.
  MASC_SEARXNG_CONTAINER    Container name. Defaults to masc-searxng.
  MASC_SEARXNG_IMAGE        Docker image. Defaults to searxng/searxng:latest.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is required"
}

searxng_url() {
  printf '%s\n' "${MASC_SEARXNG_URL:-http://localhost:$PORT}"
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
  cat >"$settings" <<EOF
use_default_settings: true

search:
  formats:
    - html
    - json

server:
  bind_address: "0.0.0.0"
  port: $CONTAINER_PORT
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
    docker run \
      --name "$CONTAINER" \
      -d \
      --restart unless-stopped \
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
