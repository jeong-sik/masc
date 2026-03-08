#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKLOAD_SCRIPT="$ROOT_DIR/scripts/harness/workload/team_session_local64_smoke.sh"
SERVER_EXE="${SERVER_EXE:-$ROOT_DIR/_build/default/bin/main_eio.exe}"
PORT="${MASC_LOCAL64_PORT:-8945}"
BASE_PATH="${MASC_LOCAL64_BASE_PATH:-$(mktemp -d "${TMPDIR:-/tmp}/masc-local64-smoke.XXXXXX")}"
LOG_FILE="${MASC_LOCAL64_LOG_FILE:-$BASE_PATH/server.log}"
POOL_SHARDS="${LOCAL64_POOL_TARGET_SHARDS:-1}"
POOL_STARTED="false"
SERVER_PID=""

resolve_server_exe() {
  if [ -x "$SERVER_EXE" ]; then
    return
  fi
  if [ -x "$ROOT_DIR/_build/default/masc-mcp/bin/main_eio.exe" ]; then
    SERVER_EXE="$ROOT_DIR/_build/default/masc-mcp/bin/main_eio.exe"
    return
  fi
  echo "Unable to locate main_eio.exe. Build the project first." >&2
  exit 1
}

wait_for_health() {
  local deadline=$((SECONDS + 45))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -fsS --http1.1 --max-time 5 -X POST "http://127.0.0.1:${PORT}/mcp" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  if [ "$POOL_STARTED" = "true" ]; then
    "$ROOT_DIR/scripts/llama-runtime-pool.sh" stop >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

resolve_server_exe
mkdir -p "$BASE_PATH"

if [ "$POOL_SHARDS" -gt 1 ]; then
  export MASC_LLAMA_RUNTIMES_JSON="$("$ROOT_DIR/scripts/llama-runtime-pool.sh" start --target-shards "$POOL_SHARDS")"
  POOL_STARTED="true"
fi

MCP_URL="${MCP_URL:-http://127.0.0.1:${PORT}/mcp}"
if [ "$MCP_URL" = "http://127.0.0.1:${PORT}/mcp" ]; then
  env -i \
    PATH="$PATH" \
    HOME="$HOME" \
    TMPDIR="${TMPDIR:-/tmp}" \
    LLAMA_SERVER_URL="${LLAMA_SERVER_URL:-http://127.0.0.1:8085}" \
    MASC_LLAMA_RUNTIMES_JSON="${MASC_LLAMA_RUNTIMES_JSON:-}" \
    MASC_STORAGE_TYPE=filesystem \
    MASC_BASE_PATH="$BASE_PATH" \
    MASC_GUARDIAN_ENABLED=false \
    MASC_ORCHESTRATOR_ENABLED=false \
    MASC_LODGE_ENABLED=false \
    MASC_LODGE_DAEMON_ENABLED=false \
    MASC_LODGE_NEO4J_ENABLED=false \
    GRAPHQL_API_KEY="" \
    "$SERVER_EXE" --port "$PORT" --base-path "$BASE_PATH" >"$LOG_FILE" 2>&1 &
  SERVER_PID="$!"
  if ! wait_for_health; then
    echo "local64 smoke server failed to become healthy" >&2
    cat "$LOG_FILE" >&2 || true
    exit 1
  fi
fi

export MCP_URL
exec "$WORKLOAD_SCRIPT" "$@"
