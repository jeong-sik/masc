#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WRAPPER_SCRIPT="$ROOT_DIR/scripts/harness_team_session_local64_smoke.sh"

MATRIX_FILE="${LOCAL64_MODEL_MATRIX_FILE:-}"
MATRIX_JSON="${LOCAL64_MODEL_MATRIX_JSON:-}"
OUTPUT_DIR="${LOCAL64_MATRIX_OUTPUT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/masc-local64-matrix.XXXXXX")}"
BASE_SEED_PORT="${LOCAL64_MATRIX_BASE_SEED_PORT:-8185}"
BASE_MCP_PORT="${LOCAL64_MATRIX_BASE_MCP_PORT:-9045}"
PORT_STRIDE="${LOCAL64_MATRIX_PORT_STRIDE:-10}"
DEFAULT_SPAWN_TIMEOUT="${SPAWN_TIMEOUT_SEC:-}"
DEFAULT_SESSION_DURATION="${SESSION_DURATION_SEC:-1800}"

usage() {
  cat <<'EOF'
Usage: scripts/harness_local64_model_matrix.sh

Inputs:
  LOCAL64_MODEL_MATRIX_FILE=/abs/path/to/matrix.json
  or
  LOCAL64_MODEL_MATRIX_JSON='[{"alias":"model","model_path":"/abs/model.gguf"}]'

Optional per-entry fields:
  label, alias, model_path, target_shards, worker_count, parallel, ctx,
  batch_size, ubatch_size

Outputs:
  summary.jsonl
  summary.json
  per-run directories with run.log, server.log, pool-state/, base/
EOF
}

require_tools() {
  command -v jq >/dev/null 2>&1 || {
    echo "jq is required" >&2
    exit 1
  }
}

load_matrix() {
  if [ -n "$MATRIX_FILE" ]; then
    cat "$MATRIX_FILE"
    return 0
  fi
  if [ -n "$MATRIX_JSON" ]; then
    printf '%s\n' "$MATRIX_JSON"
    return 0
  fi
  usage >&2
  exit 1
}

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs '[:alnum:]' '-' \
    | sed 's/^-//; s/-$//'
}

require_tools
mkdir -p "$OUTPUT_DIR"

matrix_payload="$(load_matrix)"
if ! printf '%s' "$matrix_payload" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "model matrix must be a JSON array" >&2
  exit 1
fi

summary_jsonl="$OUTPUT_DIR/summary.jsonl"
: >"$summary_jsonl"

run_index=0
while IFS= read -r item || [ -n "$item" ]; do
  run_index=$((run_index + 1))

  alias_name="$(printf '%s' "$item" | jq -r '.alias // empty')"
  model_path="$(printf '%s' "$item" | jq -r '.model_path // empty')"
  label="$(printf '%s' "$item" | jq -r --arg fallback "${alias_name:-run-$run_index}" '.label // $fallback')"
  target_shards="$(printf '%s' "$item" | jq -r '.target_shards // 1')"
  worker_count="$(printf '%s' "$item" | jq -r '(.worker_count // ((.target_shards // 1) * 8))')"
  parallel="$(printf '%s' "$item" | jq -r '.parallel // 12')"
  ctx_size="$(printf '%s' "$item" | jq -r '.ctx // 262144')"
  batch_size="$(printf '%s' "$item" | jq -r '.batch_size // 4096')"
  ubatch_size="$(printf '%s' "$item" | jq -r '.ubatch_size // 1024')"

  if [ -z "$model_path" ]; then
    echo "matrix item $run_index missing model_path" >&2
    exit 1
  fi
  if [ -z "$alias_name" ]; then
    alias_name="$(basename "$model_path" .gguf)"
  fi

  slug="$(slugify "$label")"
  run_dir="$OUTPUT_DIR/$(printf '%02d' "$run_index")-${slug}"
  base_path="$run_dir/base"
  pool_state_dir="$run_dir/pool-state"
  run_log="$run_dir/run.log"
  server_log="$run_dir/server.log"
  seed_port=$((BASE_SEED_PORT + ((run_index - 1) * PORT_STRIDE)))
  mcp_port=$((BASE_MCP_PORT + run_index - 1))

  mkdir -p "$run_dir"

  env_args=(
    MASC_LOCAL_RUNTIME_POOL_STATE_DIR="$pool_state_dir"
    MASC_LOCAL64_BASE_PATH="$base_path"
    MASC_LOCAL64_LOG_FILE="$server_log"
    MASC_LOCAL64_PORT="$mcp_port"
    LOCAL64_POOL_TARGET_SHARDS="$target_shards"
    LOCAL64_POOL_FORCE_START=true
    LLAMA_POOL_SEED_PORT="$seed_port"
    LLAMA_MODEL_PATH="$model_path"
    LLAMA_SWARM_MODEL="$alias_name"
    LLAMA_POOL_PARALLEL="$parallel"
    LLAMA_POOL_CTX="$ctx_size"
    LLAMA_POOL_BATCH_SIZE="$batch_size"
    LLAMA_POOL_UBATCH_SIZE="$ubatch_size"
    WORKER_COUNT="$worker_count"
    SESSION_DURATION_SEC="$DEFAULT_SESSION_DURATION"
  )
  if [ -n "$DEFAULT_SPAWN_TIMEOUT" ]; then
    env_args+=(SPAWN_TIMEOUT_SEC="$DEFAULT_SPAWN_TIMEOUT")
  fi

  set +e
  env \
    "${env_args[@]}" \
    "$WRAPPER_SCRIPT" >"$run_log" 2>&1
  exit_code=$?
  set -e

  session_id="$(rg -o 'session_id=[^[:space:]]+' "$run_log" | tail -n1 | cut -d= -f2- || true)"
  session_dir=""
  if [ -n "$session_id" ] && [ -d "$base_path/.masc/team-sessions/$session_id" ]; then
    session_dir="$base_path/.masc/team-sessions/$session_id"
  fi

  events_path=""
  session_path=""
  spawn_success_count=0
  turn_count=0
  assigned_runtime_counts='{}'
  if [ -n "$session_dir" ] && [ -f "$session_dir/events.jsonl" ]; then
    events_path="$session_dir/events.jsonl"
    session_path="$session_dir/session.json"
    spawn_success_count="$(jq -sc 'map(select(.event_type=="team_step_spawn" and .detail.success==true)) | length' "$events_path")"
    turn_count="$(jq -sc 'map(select(.event_type=="team_turn")) | length' "$events_path")"
    assigned_runtime_counts="$(jq -sc 'map(select(.event_type=="team_step_spawn" and .detail.success==true) | .detail.assigned_runtime) | group_by(.) | map({ (.[0]): length }) | add // {}' "$events_path")"
  fi

  failure_excerpt="$(
    {
      rg -m1 'FAIL:|Insufficient Memory|Connection refused|Abort trap|failed to start|unknown model architecture' "$run_log" "$pool_state_dir"/llama-*.log 2>/dev/null || true
    } | head -n1
  )"

  jq -cn \
    --arg label "$label" \
    --arg alias_name "$alias_name" \
    --arg model_path "$model_path" \
    --argjson target_shards "$target_shards" \
    --argjson worker_count "$worker_count" \
    --argjson parallel "$parallel" \
    --argjson ctx_size "$ctx_size" \
    --argjson batch_size "$batch_size" \
    --argjson ubatch_size "$ubatch_size" \
    --argjson seed_port "$seed_port" \
    --argjson mcp_port "$mcp_port" \
    --argjson exit_code "$exit_code" \
    --arg session_id "$session_id" \
    --arg run_dir "$run_dir" \
    --arg run_log "$run_log" \
    --arg server_log "$server_log" \
    --arg pool_state_dir "$pool_state_dir" \
    --arg events_path "$events_path" \
    --arg session_path "$session_path" \
    --arg failure_excerpt "$failure_excerpt" \
    --argjson spawn_success_count "$spawn_success_count" \
    --argjson turn_count "$turn_count" \
    --argjson assigned_runtime_counts "$assigned_runtime_counts" \
    '{
      label:$label,
      alias:$alias_name,
      model_path:$model_path,
      target_shards:$target_shards,
      worker_count:$worker_count,
      parallel:$parallel,
      ctx_size:$ctx_size,
      batch_size:$batch_size,
      ubatch_size:$ubatch_size,
      seed_port:$seed_port,
      mcp_port:$mcp_port,
      exit_code:$exit_code,
      passed:($exit_code == 0),
      session_id:(if $session_id == "" then null else $session_id end),
      run_dir:$run_dir,
      run_log:$run_log,
      server_log:$server_log,
      pool_state_dir:$pool_state_dir,
      events_path:(if $events_path == "" then null else $events_path end),
      session_path:(if $session_path == "" then null else $session_path end),
      spawn_success_count:$spawn_success_count,
      turn_count:$turn_count,
      assigned_runtime_counts:$assigned_runtime_counts,
      failure_excerpt:(if $failure_excerpt == "" then null else $failure_excerpt end)
    }' >>"$summary_jsonl"
done < <(printf '%s' "$matrix_payload" | jq -c '.[]')

jq -s . "$summary_jsonl" >"$OUTPUT_DIR/summary.json"
jq -r '.[] | [.label, (if .passed then "PASS" else "FAIL" end), (.target_shards|tostring), (.worker_count|tostring), (.spawn_success_count|tostring), (.turn_count|tostring), (.failure_excerpt // "")] | @tsv' "$OUTPUT_DIR/summary.json"
echo
echo "summary=$OUTPUT_DIR/summary.json"
