#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_WORKLOAD_SCRIPT="$ROOT_DIR/scripts/harness/workload/team_session_local64_smoke.sh"
WORKLOAD_SCRIPT="${WORKLOAD_SCRIPT_OVERRIDE:-$DEFAULT_WORKLOAD_SCRIPT}"
SERVER_EXE="${SERVER_EXE:-$ROOT_DIR/_build/default/bin/main_eio.exe}"
PORT="${MASC_LOCAL64_PORT:-8945}"
BASE_PATH="${MASC_LOCAL64_BASE_PATH:-$(mktemp -d "${TMPDIR:-/tmp}/masc-local64-smoke.XXXXXX")}"
LOG_FILE="${MASC_LOCAL64_LOG_FILE:-$BASE_PATH/server.log}"
POOL_SHARDS="${LOCAL64_POOL_TARGET_SHARDS:-1}"
SEED_PORT="${LLAMA_POOL_SEED_PORT:-8085}"
POOL_FORCE_START="${LOCAL64_POOL_FORCE_START:-false}"
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

port_in_use() {
  if ! command -v lsof >/dev/null 2>&1; then
    return 1
  fi
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1
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
export MASC_LOCAL64_BASE_PATH="$BASE_PATH"

need_pool_start="false"
if [ "$POOL_SHARDS" -gt 1 ] || [ "$POOL_FORCE_START" = "true" ]; then
  need_pool_start="true"
elif [ -n "${LLAMA_MODEL_PATH:-}" ]; then
  if ! curl -fsS --max-time 3 "http://127.0.0.1:${SEED_PORT}/v1/models" >/dev/null 2>&1; then
    need_pool_start="true"
  fi
fi

if [ "$need_pool_start" = "true" ]; then
  export MASC_LLAMA_RUNTIMES_JSON="$("$ROOT_DIR/scripts/llama-runtime-pool.sh" start --target-shards "$POOL_SHARDS" --seed-port "$SEED_PORT")"
  POOL_STARTED="true"
fi

discovered_models_json=""
if command -v jq >/dev/null 2>&1; then
  if [ -n "${MASC_LLAMA_RUNTIMES_JSON:-}" ]; then
    discovered_models_json="$(printf '%s' "$MASC_LLAMA_RUNTIMES_JSON" | jq -c '[.[] | .model // empty | select(type == "string" and . != "")]')"
  else
    model_probe_url="${LLAMA_SERVER_URL:-http://127.0.0.1:${SEED_PORT}}/v1/models"
    model_probe_raw="$(curl -fsS --max-time 5 "$model_probe_url" 2>/dev/null || true)"
    if [ -n "${model_probe_raw:-}" ]; then
      discovered_models_json="$(printf '%s' "$model_probe_raw" | jq -c '[.data[]? | .id // empty | select(type == "string" and . != "")]' 2>/dev/null || true)"
    fi
  fi
fi

if command -v jq >/dev/null 2>&1 && [ -n "${discovered_models_json:-}" ]; then
  if [ -z "${MASC_TEAM_SESSION_MODEL_35B:-}" ]; then
    inferred_lead_model="$(printf '%s' "$discovered_models_json" | jq -r '.[0] // empty')"
    if [ -n "${inferred_lead_model:-}" ]; then
      export MASC_TEAM_SESSION_MODEL_35B="$inferred_lead_model"
    fi
  fi
  if [ -z "${MASC_TEAM_SESSION_MODEL_9B:-}" ]; then
    inferred_worker_model="$(printf '%s' "$discovered_models_json" | jq -r '[.[] | select(ascii_downcase | contains("9b"))] | .[0] // empty')"
    if [ -n "${inferred_worker_model:-}" ]; then
      export MASC_TEAM_SESSION_MODEL_9B="$inferred_worker_model"
    fi
  fi
fi

MCP_URL="${MCP_URL:-http://127.0.0.1:${PORT}/mcp}"
if [ "$MCP_URL" = "http://127.0.0.1:${PORT}/mcp" ]; then
  if port_in_use; then
    echo "local64 smoke refused to start: port ${PORT} is already listening; choose a fresh MASC_LOCAL64_PORT or set MCP_URL explicitly" >&2
    exit 1
  fi
  env -i \
    PATH="$PATH" \
    HOME="$HOME" \
    TMPDIR="${TMPDIR:-/tmp}" \
    LLAMA_SERVER_URL="${LLAMA_SERVER_URL:-http://127.0.0.1:${SEED_PORT}}" \
    MASC_LLAMA_RUNTIMES_JSON="${MASC_LLAMA_RUNTIMES_JSON:-}" \
    MASC_LLAMA_RUNTIME_COOLDOWN_SEC="${MASC_LLAMA_RUNTIME_COOLDOWN_SEC:-}" \
    MASC_LLAMA_RUNTIME_DEBUG="${MASC_LLAMA_RUNTIME_DEBUG:-}" \
    MASC_TEAM_SESSION_MODEL_35B="${MASC_TEAM_SESSION_MODEL_35B:-}" \
    MASC_TEAM_SESSION_MODEL_9B="${MASC_TEAM_SESSION_MODEL_9B:-}" \
    MASC_TEAM_SESSION_ROUTER_JUDGE="${MASC_TEAM_SESSION_ROUTER_JUDGE:-}" \
    MASC_TEAM_SESSION_ROUTER_JUDGE_MODEL="${MASC_TEAM_SESSION_ROUTER_JUDGE_MODEL:-}" \
    MASC_TEAM_SESSION_ROUTER_CONFIDENCE_THRESHOLD="${MASC_TEAM_SESSION_ROUTER_CONFIDENCE_THRESHOLD:-}" \
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

export MASC_LOCAL64_SERVER_PID="${SERVER_PID:-}"
export MASC_LOCAL64_LOG_FILE="${LOG_FILE:-}"
export MCP_URL
exec bash "$WORKLOAD_SCRIPT" "$@"
