#!/usr/bin/env bash
# Shared helpers for observability smoke harness scripts.
# Source after mcp_jsonrpc.sh and server_bootstrap.sh.

PASS_COUNT=0
FAIL_COUNT=0

# Exit code 2 = skipped (distinct from 0=pass, 1=fail).
# Set OBS_PERMISSIVE=1 to treat skips as exit 0 for local dev convenience.
OBS_SKIP_EXIT=2
case "${OBS_PERMISSIVE:-}" in
  1|true|TRUE|yes|YES)
    OBS_SKIP_EXIT=0
    ;;
esac

obs_skip() {
  echo "SKIP: $1"
  exit "$OBS_SKIP_EXIT"
}

obs_require_commands() {
  for cmd in jq curl python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      obs_skip "$cmd not found"
    fi
  done
}

obs_require_server_exe() {
  local root_dir="$1"
  local exe
  exe="$(harness_find_server_exe "$root_dir" "${SERVER_EXE:-}")" || {
    obs_skip "server executable not found (run: dune build)"
  }
  printf '%s\n' "$exe"
}

assert_no_api_key() {
  local text="$1"
  if printf '%s' "$text" | grep -qE '(sk-[a-zA-Z0-9]{20,}|key-[a-zA-Z0-9]{20,}|AIza[a-zA-Z0-9]{30,})'; then
    echo "FAIL: found raw API key in preview text"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return 1
  fi
  PASS_COUNT=$((PASS_COUNT + 1))
  return 0
}

assert_max_length() {
  local text="$1" max="${2:-200}"
  local len=${#text}
  if [ "$len" -gt "$max" ]; then
    echo "FAIL: length $len exceeds max $max"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return 1
  fi
  PASS_COUNT=$((PASS_COUNT + 1))
  return 0
}

assert_gte() {
  local actual="$1" expected="$2" label="${3:-value}"
  if [ "$actual" -ge "$expected" ] 2>/dev/null; then
    PASS_COUNT=$((PASS_COUNT + 1))
    return 0
  fi
  echo "FAIL: $label: $actual < $expected"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  return 1
}

# Wait for health with state_ready check (stricter than harness_wait_for_health)
obs_wait_for_ready() {
  local port="$1" timeout="${2:-30}"
  local deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local health_json
    health_json="$(curl -fsS --http1.1 --max-time 2 "http://127.0.0.1:${port}/health" 2>/dev/null || true)"
    if [ -n "$health_json" ]; then
      local ready
      ready="$(printf '%s' "$health_json" | jq -r '.startup.state_ready // false' 2>/dev/null || echo "false")"
      if [ "$ready" = "true" ]; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

# Start isolated server for smoke tests (PG/gRPC/WS disabled)
obs_start_server() {
  local server_exe="$1" port="$2" base_path="$3" log_file="$4"
  mkdir -p "$base_path"
  env \
    MASC_BASE_PATH="$base_path" \
    MASC_STORAGE_TYPE="filesystem" \
    MASC_AUTONOMY_ENABLED="0" \
    MASC_ORCHESTRATOR_ENABLED="0" \
    MASC_ALLOW_LEGACY_ACCEPT="1" \
    MASC_GRPC_ENABLED="0" \
    MASC_WEBSOCKET_ENABLED="0" \
    MASC_WEBRTC_ENABLED="0" \
    MASC_POSTGRES_URL="" \
    DATABASE_URL="" \
    SUPABASE_DB_URL="" \
    SB_PG_URL="" \
    GRAPHQL_API_KEY="" \
    GRAPHQL_URL="http://127.0.0.1:9/graphql" \
    MASC_BOARD_BACKEND="jsonl" \
    "$server_exe" --port "$port" --base-path "$base_path" \
    >"$log_file" 2>&1 &
  printf '%s\n' "$!"
}

# Bootstrap room: init + join, returns nickname
# Usage: obs_bootstrap_room <mcp_url> <session_id> <agent_name> [capabilities_json_array]
obs_bootstrap_room() {
  local mcp_url="$1" session_id="$2" agent_name="$3"
  local capabilities="${4:-[\"supervisor\",\"operator\",\"team-session\"]}"
  local init_raw join_raw nickname

  init_raw="$(mcp_call_tool 1 "masc_init" "$(jq -cn --arg a "$agent_name" '{agent_name:$a}')" "$session_id" "" "$mcp_url")"
  mcp_require_tool_ok "$init_raw" "masc_init" || return 1

  local join_args
  join_args="$(jq -cn --arg name "$agent_name" --argjson caps "$capabilities" '{agent_name: $name, capabilities: $caps}')"
  join_raw="$(mcp_call_tool 2 "masc_join" "$join_args" "$session_id" "" "$mcp_url")"
  mcp_require_tool_ok "$join_raw" "masc_join" || return 1

  nickname="$(printf '%s' "$join_raw" | mcp_extract_text | sed -n 's/^  Nickname: //p' | head -n1)"
  if [ -z "$nickname" ]; then
    nickname="$(printf '%s' "$join_raw" | mcp_extract_result | jq -r '.nickname // .agent_name // "unknown"' 2>/dev/null)"
  fi
  printf '%s\n' "$nickname"
}
