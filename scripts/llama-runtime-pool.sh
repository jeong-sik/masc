#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${MASC_LOCAL_RUNTIME_POOL_STATE_DIR:-${MASC_LLAMA_RUNTIME_POOL_STATE_DIR:-${TMPDIR:-/tmp}/masc-local-runtime-pool}}"
TARGET_SHARDS="${LLAMA_POOL_TARGET_SHARDS:-6}"
BASE_HOST="${LLAMA_POOL_HOST:-127.0.0.1}"
DEFAULT_PARALLEL="${LLAMA_POOL_PARALLEL:-12}"
DEFAULT_CTX="${LLAMA_POOL_CTX:-262144}"
DEFAULT_BATCH="${LLAMA_POOL_BATCH_SIZE:-4096}"
DEFAULT_UBATCH="${LLAMA_POOL_UBATCH_SIZE:-1024}"
DEFAULT_CHAT_TEMPLATE="${LLAMA_POOL_CHAT_TEMPLATE:-chatml}"
DEFAULT_CHAT_TEMPLATE_KWARGS="${LLAMA_POOL_CHAT_TEMPLATE_KWARGS:-{\"enable_thinking\":false}}"
SEED_BINARY=""

extract_port_from_url() {
  local url="${1:-}"
  local host_port=""
  if [ -z "$url" ]; then
    return 0
  fi
  host_port="${url#*://}"
  host_port="${host_port%%/*}"
  if [[ "$host_port" == *:* ]]; then
    printf '%s\n' "${host_port##*:}"
  fi
}

DEFAULT_SEED_PORT="$(extract_port_from_url "${LLAMA_POOL_SEED_URL:-${OAS_LOCAL_LLM_URL:-${LLAMA_SERVER_URL:-}}}")"
SEED_PORT="${LLAMA_POOL_SEED_PORT:-$DEFAULT_SEED_PORT}"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required but not found in PATH" >&2
  exit 1
fi

mkdir -p "$STATE_DIR"

usage() {
  cat <<'EOF'
Usage: scripts/llama-runtime-pool.sh <start|status|stop|print-env|bench> [options]

Options:
  --target-shards N   Total runtime count including the seed port (default: 6)
  --seed-port PORT    Seed runtime port to clone from
EOF
}

require_seed_port() {
  if [ -z "${SEED_PORT:-}" ]; then
    echo "Missing seed runtime port. Set LLAMA_POOL_SEED_PORT or LLAMA_POOL_SEED_URL/OAS_LOCAL_LLM_URL/LLAMA_SERVER_URL." >&2
    exit 1
  fi
}

extract_flag_value() {
  local flag="$1"
  shift
  local tokens=("$@")
  local idx
  for ((idx=0; idx<${#tokens[@]}-1; idx++)); do
    if [ "${tokens[$idx]}" = "$flag" ]; then
      printf '%s' "${tokens[$((idx + 1))]}"
      return 0
    fi
  done
  return 1
}

has_flag() {
  local flag="$1"
  shift
  local token
  for token in "$@"; do
    if [ "$token" = "$flag" ]; then
      return 0
    fi
  done
  return 1
}

seed_command() {
  ps -ax -o pid=,command= | while read -r pid rest; do
    case "$rest" in
      *llama-server*"--port ${SEED_PORT}"*) printf '%s\n' "$rest"; return 0 ;;
    esac
  done
}

resolve_seed_args() {
  require_seed_port
  local seed_cmd
  seed_cmd="$(seed_command || true)"
  if [ -n "$seed_cmd" ]; then
    read -r -a TOKENS <<<"$seed_cmd"
    SEED_BINARY="${TOKENS[0]}"
    MODEL_PATH="$(extract_flag_value "-m" "${TOKENS[@]}" || true)"
    MODEL_ALIAS="$(extract_flag_value "--alias" "${TOKENS[@]}" || true)"
    NGL="$(extract_flag_value "-ngl" "${TOKENS[@]}" || printf '999')"
    CTX_SIZE="$(extract_flag_value "-c" "${TOKENS[@]}" || printf '%s' "$DEFAULT_CTX")"
    PARALLEL="$(extract_flag_value "--parallel" "${TOKENS[@]}" || printf '%s' "$DEFAULT_PARALLEL")"
    BATCH_SIZE="$(extract_flag_value "--batch-size" "${TOKENS[@]}" || printf '%s' "$DEFAULT_BATCH")"
    UBATCH_SIZE="$(extract_flag_value "--ubatch-size" "${TOKENS[@]}" || printf '%s' "$DEFAULT_UBATCH")"
    TEMP="$(extract_flag_value "--temp" "${TOKENS[@]}" || printf '0.6')"
    TOP_P="$(extract_flag_value "--top-p" "${TOKENS[@]}" || printf '0.95')"
    TOP_K="$(extract_flag_value "--top-k" "${TOKENS[@]}" || printf '20')"
    MIN_P="$(extract_flag_value "--min-p" "${TOKENS[@]}" || printf '0.01')"
    CACHE_REUSE="$(extract_flag_value "--cache-reuse" "${TOKENS[@]}" || printf '256')"
    CACHE_TYPE_K="$(extract_flag_value "--cache-type-k" "${TOKENS[@]}" || printf 'q8_0')"
    CACHE_TYPE_V="$(extract_flag_value "--cache-type-v" "${TOKENS[@]}" || printf 'q8_0')"
    CRAM_VALUE="$(extract_flag_value "-cram" "${TOKENS[@]}" || printf -- '-1')"
    CTX_CHECKPOINTS="$(extract_flag_value "--ctx-checkpoints" "${TOKENS[@]}" || printf '32')"
    CHAT_TEMPLATE="$(extract_flag_value "--chat-template" "${TOKENS[@]}" || printf '%s' "$DEFAULT_CHAT_TEMPLATE")"
    CHAT_TEMPLATE_KWARGS="$(extract_flag_value "--chat-template-kwargs" "${TOKENS[@]}" || printf '%s' "$DEFAULT_CHAT_TEMPLATE_KWARGS")"
    FLASH_ATTN="$(extract_flag_value "--flash-attn" "${TOKENS[@]}" || printf 'on')"
    HOST="$(extract_flag_value "--host" "${TOKENS[@]}" || printf '%s' "$BASE_HOST")"
    SEED_HAS_NO_WARMUP="false"; has_flag "--no-warmup" "${TOKENS[@]}" && SEED_HAS_NO_WARMUP="true"
    SEED_HAS_CACHE_PROMPT="false"; has_flag "--cache-prompt" "${TOKENS[@]}" && SEED_HAS_CACHE_PROMPT="true"
    SEED_HAS_SLOTS="false"; has_flag "--slots" "${TOKENS[@]}" && SEED_HAS_SLOTS="true"
    SEED_HAS_SWA_FULL="false"; has_flag "--swa-full" "${TOKENS[@]}" && SEED_HAS_SWA_FULL="true"
    SEED_HAS_KV_UNIFIED="false"; has_flag "--kv-unified" "${TOKENS[@]}" && SEED_HAS_KV_UNIFIED="true"
  else
    MODEL_PATH="${LLAMA_MODEL_PATH:-}"
    MODEL_ALIAS="${LLAMA_SWARM_MODEL:-}"
    NGL="${LLAMA_POOL_NGL:-999}"
    CTX_SIZE="$DEFAULT_CTX"
    PARALLEL="$DEFAULT_PARALLEL"
    BATCH_SIZE="$DEFAULT_BATCH"
    UBATCH_SIZE="$DEFAULT_UBATCH"
    TEMP="0.6"
    TOP_P="0.95"
    TOP_K="20"
    MIN_P="0.01"
    CACHE_REUSE="256"
    CACHE_TYPE_K="q8_0"
    CACHE_TYPE_V="q8_0"
    CRAM_VALUE="-1"
    CTX_CHECKPOINTS="32"
    CHAT_TEMPLATE="$DEFAULT_CHAT_TEMPLATE"
    CHAT_TEMPLATE_KWARGS="$DEFAULT_CHAT_TEMPLATE_KWARGS"
    FLASH_ATTN="on"
    HOST="$BASE_HOST"
    SEED_HAS_NO_WARMUP="true"
    SEED_HAS_CACHE_PROMPT="true"
    SEED_HAS_SLOTS="true"
    SEED_HAS_SWA_FULL="true"
    SEED_HAS_KV_UNIFIED="true"
  fi

  if [ -z "${MODEL_PATH:-}" ] || [ -z "${MODEL_ALIAS:-}" ]; then
    echo "Missing seed llama model configuration. Need running seed on port ${SEED_PORT} or LLAMA_MODEL_PATH + LLAMA_SWARM_MODEL." >&2
    exit 1
  fi
}

resolve_llama_server_bin() {
  local discovered=""
  if [ -n "${LLAMA_SERVER_BIN:-}" ] && [ -x "${LLAMA_SERVER_BIN}" ]; then
    printf '%s\n' "${LLAMA_SERVER_BIN}"
    return 0
  fi
  if [ -n "${SEED_BINARY:-}" ] && [ -x "${SEED_BINARY}" ]; then
    printf '%s\n' "${SEED_BINARY}"
    return 0
  fi
  if [ -x "$HOME/me/.local/bin/llama-server" ]; then
    printf '%s\n' "$HOME/me/.local/bin/llama-server"
    return 0
  fi
  if [ -x "$HOME/.local/bin/llama-server" ]; then
    printf '%s\n' "$HOME/.local/bin/llama-server"
    return 0
  fi
  discovered="$(type -P llama-server 2>/dev/null || true)"
  if [ -n "$discovered" ] && [ -x "$discovered" ]; then
    printf '%s\n' "$discovered"
    return 0
  fi
  echo "Unable to locate llama-server. Set LLAMA_SERVER_BIN explicitly." >&2
  return 1
}

runtime_id() {
  local port="$1"
  printf 'llama-%s' "$port"
}

runtime_url() {
  local port="$1"
  printf 'http://%s:%s' "$BASE_HOST" "$port"
}

port_is_listening() {
  lsof -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1
}

chat_probe_payload() {
  jq -cn --arg model "$1" \
    '{model:$model,messages:[{role:"user",content:"ping"}],max_tokens:1,temperature:0}'
}

chat_contract_status() {
  local port="$1"
  local payload body status rc
  payload="$(chat_probe_payload "$MODEL_ALIAS")"
  if body="$(curl -sS --http1.1 --max-time 15 \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    -w '\n%{http_code}' \
    "$(runtime_url "$port")/v1/chat/completions" 2>/dev/null)"; then
    rc=0
  else
    rc=$?
  fi
  if [ "${rc:-0}" -ne 0 ]; then
    printf 'unknown'
    return 0
  fi
  status="${body##*$'\n'}"
  body="${body%$'\n'*}"
  if [ "$status" = "200" ] && printf '%s' "$body" | jq -e '.choices | type == "array"' >/dev/null 2>&1; then
    printf 'confirmed'
  elif [[ "$status" =~ ^(400|404|405|415|422)$ ]]; then
    printf 'rejected'
  else
    printf 'unknown'
  fi
}

wait_for_runtime() {
  local port="$1"
  local deadline=$((SECONDS + 45))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -fsS --max-time 5 "$(runtime_url "$port")/v1/models" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

start_shard() {
  local port="$1"
  local slot_dir="$STATE_DIR/slots-$port"
  local log_file="$STATE_DIR/llama-$port.log"
  local pid_file="$STATE_DIR/llama-$port.pid"
  local server_bin
  mkdir -p "$slot_dir"
  if port_is_listening "$port"; then
    return 0
  fi
  server_bin="$(resolve_llama_server_bin)"

  local -a cmd=(
    "$server_bin"
    -m "$MODEL_PATH"
    --alias "$MODEL_ALIAS"
    -c "$CTX_SIZE"
    -ngl "$NGL"
    --port "$port"
    --host "$HOST"
    --parallel "$PARALLEL"
    --temp "$TEMP"
    --top-p "$TOP_P"
    --top-k "$TOP_K"
    --min-p "$MIN_P"
    --batch-size "$BATCH_SIZE"
    --ubatch-size "$UBATCH_SIZE"
    --flash-attn "$FLASH_ATTN"
    --cache-reuse "$CACHE_REUSE"
    --cache-type-k "$CACHE_TYPE_K"
    --cache-type-v "$CACHE_TYPE_V"
    --slot-save-path "$slot_dir"
    -cram "$CRAM_VALUE"
    --ctx-checkpoints "$CTX_CHECKPOINTS"
    --chat-template "$CHAT_TEMPLATE"
    --chat-template-kwargs "$CHAT_TEMPLATE_KWARGS"
  )
  [ "$SEED_HAS_NO_WARMUP" = "true" ] && cmd+=(--no-warmup)
  [ "$SEED_HAS_CACHE_PROMPT" = "true" ] && cmd+=(--cache-prompt)
  [ "$SEED_HAS_SLOTS" = "true" ] && cmd+=(--slots)
  [ "$SEED_HAS_SWA_FULL" = "true" ] && cmd+=(--swa-full)
  [ "$SEED_HAS_KV_UNIFIED" = "true" ] && cmd+=(--kv-unified)

  "${cmd[@]}" >"$log_file" 2>&1 &
  echo "$!" >"$pid_file"
  if ! wait_for_runtime "$port"; then
    echo "Shard on port $port failed to start" >&2
    if [ -f "$pid_file" ]; then
      kill "$(cat "$pid_file")" >/dev/null 2>&1 || true
      rm -f "$pid_file"
    fi
    return 1
  fi
}

print_env_value() {
  require_seed_port
  resolve_seed_args
  local max_port=$((SEED_PORT + TARGET_SHARDS - 1))
  local endpoints=()
  local port contract_status
  for port in $(seq "$SEED_PORT" "$max_port"); do
    if ! port_is_listening "$port"; then
      continue
    fi
    contract_status="$(chat_contract_status "$port")"
    if [ "$contract_status" != "rejected" ]; then
      endpoints+=("$(runtime_url "$port")")
      if [ "$contract_status" = "unknown" ]; then
        echo "warning: including $(runtime_id "$port") in runtime pool with unconfirmed chat contract (probe timed out or transport failed)" >&2
      fi
    else
      echo "warning: excluding $(runtime_id "$port") from runtime pool; /v1/chat/completions contract probe failed" >&2
    fi
  done
  local joined=""
  local endpoint
  for endpoint in "${endpoints[@]}"; do
    if [ -n "$joined" ]; then
      joined+=","
    fi
    joined+="$endpoint"
  done
  printf '%s\n' "$joined"
}

start_pool() {
  require_seed_port
  resolve_seed_args
  local max_port=$((SEED_PORT + TARGET_SHARDS - 1))
  local failures=0
  local port
  for port in $(seq "$SEED_PORT" "$max_port"); do
    start_shard "$port" || failures=$((failures + 1))
  done
  print_env_value
  if [ "$failures" -gt 0 ]; then
    echo "warning: $failures shard(s) failed to start" >&2
  fi
}

status_pool() {
  require_seed_port
  resolve_seed_args
  local port contract_status
  local max_port=$((SEED_PORT + TARGET_SHARDS - 1))
  for port in $(seq "$SEED_PORT" "$max_port"); do
    printf '%s\t%s\t' "$(runtime_id "$port")" "$(runtime_url "$port")"
    if port_is_listening "$port"; then
      contract_status="$(chat_contract_status "$port")"
      if [ "$contract_status" = "confirmed" ]; then
        printf 'up-chat\n'
      elif [ "$contract_status" = "unknown" ]; then
        printf 'up-unknown\n'
      else
        printf 'up-nochat\n'
      fi
    else
      printf 'down\n'
    fi
  done
  print_env_value
}

stop_pool() {
  local pid_file
  for pid_file in "$STATE_DIR"/llama-*.pid; do
    [ -f "$pid_file" ] || continue
    kill "$(cat "$pid_file")" >/dev/null 2>&1 || true
    rm -f "$pid_file"
  done
}

bench_pool() {
  if [ -z "${MCP_URL:-}" ]; then
    echo "MCP_URL is required for bench" >&2
    exit 1
  fi
  local parallelism="${PARALLELISM:-32}"
  local rounds="${ROUNDS:-1}"
  curl -sS --http1.1 --max-time 120 -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "$(jq -cn \
      --argjson parallelism "$parallelism" \
      --argjson rounds "$rounds" \
      '{jsonrpc:"2.0",id:9001,method:"tools/call",params:{name:"masc_llama_runtime_bench",arguments:{parallelism:$parallelism,rounds:$rounds,runtime_pool:"local64"}}}')" \
    | jq .
}

COMMAND="${1:-}"
shift || true

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target-shards)
      TARGET_SHARDS="$2"
      shift 2
      ;;
    --seed-port)
      SEED_PORT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

case "$COMMAND" in
  start) start_pool ;;
  status) status_pool ;;
  stop) stop_pool ;;
  print-env) print_env_value ;;
  bench) bench_pool ;;
  *)
    usage
    exit 1
    ;;
esac
