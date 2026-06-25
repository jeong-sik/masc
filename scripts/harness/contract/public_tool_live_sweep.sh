#!/usr/bin/env bash
set -euo pipefail

: "${MCP_URL:=http://127.0.0.1:8935/mcp}"
: "${BASE_PATH:?BASE_PATH must be set by run_all.sh}"
: "${AGENT_NAME:=${MCP_AGENT_NAME:-public-tool-sweep-harness}}"
: "${MCP_SESSION_ID:=}"
export MCP_SESSION_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${SCRIPT_DIR}/../lib/test_framework.sh"
source "${SCRIPT_DIR}/../lib/mcp_jsonrpc.sh"

response_transport_ok() {
  local payload="$1"
  printf '%s' "$payload" | jq -e '._harness_error? == null and .error == null' >/dev/null
}

response_tool_ok() {
  local payload="$1"
  response_transport_ok "$payload" &&
    printf '%s' "$payload" | jq -e '.result.isError != true' >/dev/null
}

response_text_or_error() {
  local payload="$1"
  local text
  text="$(printf '%s' "$payload" | extract_text)"
  if [[ -n "$text" ]]; then
    printf '%s\n' "$text"
    return 0
  fi
  printf '%s' "$payload" | extract_error
}

expect_ok() {
  local label="$1"
  local payload="$2"
  if response_tool_ok "$payload"; then
    echo "  PASS: ${label}"
    return 0
  fi
  mcp_fail_with_context "${label}: expected success" "$(response_text_or_error "$payload")"
}

expect_ok_or_guard() {
  local label="$1"
  local payload="$2"
  local guard_regex="$3"
  if response_tool_ok "$payload"; then
    echo "  PASS: ${label}"
    return 0
  fi
  if response_transport_ok "$payload"; then
    local text
    text="$(response_text_or_error "$payload")"
    if [[ -n "$text" ]] && printf '%s' "$text" | grep -Eiq "$guard_regex"; then
      echo "  PASS: ${label} (guard)"
      return 0
    fi
    mcp_fail_with_context "${label}: expected success or guard /${guard_regex}/" "$text"
  fi
  mcp_fail_with_context "${label}: transport/jsonrpc failure" "$payload"
}

call_method() {
  local id="$1"
  local method="$2"
  local params_json="$3"
  local raw
  raw="$(curl_post_mcp "$(jq -cn --argjson id "$id" --arg method "$method" --argjson params "$params_json" '{jsonrpc:"2.0",id:$id,method:$method,params:$params}')")"
  jsonrpc_normalize_response "$raw" "$id"
}

extract_token() {
  local text="$1"
  local pattern="$2"
  printf '%s\n' "$text" | grep -oE "$pattern" | head -n1 || true
}

manifest_json="$(
  env -u DUNE_RPC MASC_STORAGE_TYPE=filesystem \
    opam exec -- dune exec --root "$ROOT_DIR" bin/public_tool_manifest.exe \
    | awk 'BEGIN { printing = 0 } /^\{/ { printing = 1 } printing { print }'
)"
expected_public_tools="$(printf '%s\n' "$manifest_json" | jq -c '.public_tool_names | sort')"

echo "[1/27] initialize MCP session"
initialize_mcp_session || {
  echo "FAIL: failed to initialize MCP session" >&2
  exit 1
}

echo "[2/27] tools/list matches expected public surface"
tools_list_payload="$(call_method 5001 "tools/list" '{}')"
if ! response_transport_ok "$tools_list_payload"; then
  mcp_fail_with_context "tools/list failed" "$tools_list_payload"
fi
actual_public_tools="$(printf '%s' "$tools_list_payload" | jq -c '.result.tools | map(.name) | sort')"
if [[ "$actual_public_tools" != "$expected_public_tools" ]]; then
  diff_json="$(jq -cn --argjson expected "$expected_public_tools" --argjson actual "$actual_public_tools" '{expected:$expected,actual:$actual}')"
  mcp_fail_with_context "public tools/list surface drift" "$diff_json"
fi
echo "  PASS: tools/list public surface"

echo "[3/27] masc_start"
r_start="$(call_tool 5003 "masc_start" "$(jq -cn --arg path "$BASE_PATH" '{path:$path}')")"
expect_ok "masc_start" "$r_start"

echo "[4/27] masc_status"
r_status="$(call_tool 5005 "masc_status" '{}')"
expect_ok "masc_status" "$r_status"

echo "[5/27] masc_agent_card"
r_agent_card="$(call_tool 5009 "masc_agent_card" '{}')"
expect_ok "masc_agent_card" "$r_agent_card"

echo "[6/27] masc_tool_help"
r_tool_help="$(call_tool 5012 "masc_tool_help" '{"tool_name":"masc_status"}')"
expect_ok "masc_tool_help" "$r_tool_help"

echo "[7/27] masc_goal_upsert"
GOAL_SEED_PAYLOAD="$(call_tool 5014 "masc_goal_upsert" '{"title":"Public Tool Sweep Goal","priority":1}')"
GOAL_ID="$(printf '%s' "$GOAL_SEED_PAYLOAD" | extract_result | jq -r '.goal_id // empty')"
if [ -z "$GOAL_ID" ]; then
  mcp_fail_with_context "could not create goal for public tool live sweep" "$GOAL_SEED_PAYLOAD"
fi
echo "  PASS: masc_goal_upsert"

echo "[8/27] masc_goal_list"
r_goal_list="$(call_tool 5013 "masc_goal_list" '{}')"
expect_ok "masc_goal_list" "$r_goal_list"

echo "[9/27] masc_add_task"
r_add_task="$(call_tool 5014 "masc_add_task" "$(jq -cn --arg goal_id "$GOAL_ID" '{title:"Public Tool Sweep Task",goal_id:$goal_id,priority:2,description:"live public surface verification"}')")"
expect_ok "masc_add_task" "$r_add_task"
task_id="$(
  printf '%s' "$r_add_task" \
    | jq -r 'try (.result.structuredContent.task_id // .result.structuredContent.id) catch empty | strings' \
    | head -n1
)"
if [[ -z "$task_id" ]]; then
  task_id="$(response_text_or_error "$r_add_task" | grep -oE 'task-[A-Za-z0-9_-]+' | head -n1 || true)"
fi
if [[ -z "$task_id" ]]; then
  mcp_fail_with_context "masc_add_task: could not extract task_id" "$r_add_task"
fi

echo "[10/27] masc_batch_add_tasks"
r_batch_add="$(call_tool 5015 "masc_batch_add_tasks" "$(jq -cn --arg goal_id "$GOAL_ID" '{tasks:[{title:"Public Sweep Batch A",goal_id:$goal_id,priority:3,description:"batch-a"},{title:"Public Sweep Batch B",goal_id:$goal_id,priority:4,description:"batch-b"}]}')")"
expect_ok "masc_batch_add_tasks" "$r_batch_add"

echo "[11/27] masc_tasks"
r_tasks="$(call_tool 5016 "masc_tasks" '{}')"
expect_ok "masc_tasks" "$r_tasks"

echo "[12/27] masc_transition claim"
r_claim="$(call_tool 5017 "masc_transition" "$(jq -cn --arg task_id "$task_id" --arg agent_name "$AGENT_NAME" '{task_id:$task_id,agent_name:$agent_name,action:"claim",notes:"public tool sweep claim"}')")"
expect_ok "masc_transition claim" "$r_claim"

echo "[13/27] masc_plan_init"
r_plan_init="$(call_tool 5018 "masc_plan_init" "$(jq -cn --arg task_id "$task_id" '{task_id:$task_id}')")"
expect_ok "masc_plan_init" "$r_plan_init"

echo "[14/27] masc_plan_set_task"
r_plan_set="$(call_tool 5019 "masc_plan_set_task" "$(jq -cn --arg task_id "$task_id" '{task_id:$task_id}')")"
expect_ok "masc_plan_set_task" "$r_plan_set"

echo "[15/27] masc_check"
r_check="$(call_tool 5020 "masc_check" '{"assertions":["task_claimed","current_task_set"]}')"
expect_ok "masc_check" "$r_check"

echo "[16/27] masc_plan_update"
r_plan_update="$(call_tool 5020 "masc_plan_update" "$(jq -cn --arg task_id "$task_id" --arg content "public tool sweep plan" '{task_id:$task_id,content:$content}')")"
expect_ok "masc_plan_update" "$r_plan_update"

echo "[17/27] masc_plan_get"
r_plan_get="$(call_tool 5021 "masc_plan_get" "$(jq -cn --arg task_id "$task_id" '{task_id:$task_id}')")"
expect_ok "masc_plan_get" "$r_plan_get"

echo "[18/27] masc_transition start"
r_transition="$(call_tool 5022 "masc_transition" "$(jq -cn --arg task_id "$task_id" --arg agent_name "$AGENT_NAME" '{task_id:$task_id,agent_name:$agent_name,action:"start",notes:"public tool sweep start"}')")"
expect_ok "masc_transition start" "$r_transition"

echo "[19/27] masc_heartbeat"
r_heartbeat="$(call_tool 5023 "masc_heartbeat" '{}')"
expect_ok "masc_heartbeat" "$r_heartbeat"

echo "[20/27] masc_broadcast"
r_broadcast="$(call_tool 5024 "masc_broadcast" "$(jq -cn --arg agent_name "$AGENT_NAME" --arg message "public tool sweep broadcast" '{agent_name:$agent_name,message:$message}')")"
expect_ok "masc_broadcast" "$r_broadcast"

echo "[21/27] masc_messages"
r_messages="$(call_tool 5025 "masc_messages" '{}')"
expect_ok "masc_messages" "$r_messages"

echo "[22/27] masc_board_post"
r_board_post="$(call_tool 5026 "masc_board_post" "$(jq -cn --arg author "$AGENT_NAME" --arg title "Public Tool Sweep Post" --arg content "public tool sweep board post" '{author:$author,title:$title,content:$content,visibility:"internal"}')")"
expect_ok "masc_board_post" "$r_board_post"
post_id="$(
  printf '%s' "$r_board_post" \
    | jq -r 'try (.result.structuredContent.id) catch empty | strings' \
    | head -n1
)"
if [[ -z "$post_id" ]]; then
  post_id="$(response_text_or_error "$r_board_post" | grep -oE '(post|p)-[A-Za-z0-9_-]+' | head -n1 || true)"
fi
if [[ -z "$post_id" ]]; then
  mcp_fail_with_context "masc_board_post: could not extract post_id" "$r_board_post"
fi

echo "[23/27] masc_board_list"
r_board_list="$(call_tool 5027 "masc_board_list" '{"limit":5}')"
expect_ok "masc_board_list" "$r_board_list"

echo "[24/27] masc_board_post_get"
r_board_get="$(call_tool 5028 "masc_board_post_get" "$(jq -cn --arg post_id "$post_id" '{post_id:$post_id}')")"
expect_ok "masc_board_post_get" "$r_board_get"

echo "[25/27] masc_board_comment"
r_board_comment="$(call_tool 5029 "masc_board_comment" "$(jq -cn --arg post_id "$post_id" --arg author "$AGENT_NAME" --arg content "public tool sweep comment" '{post_id:$post_id,author:$author,content:$content}')")"
expect_ok "masc_board_comment" "$r_board_comment"

echo "[26/27] masc_board_vote"
r_board_vote="$(call_tool 5030 "masc_board_vote" "$(jq -cn --arg post_id "$post_id" '{post_id:$post_id}')")"
expect_ok "masc_board_vote" "$r_board_vote"

echo "[27/27] masc_transition done"
r_done="$(call_tool 5031 "masc_transition" "$(jq -cn --arg task_id "$task_id" --arg agent_name "$AGENT_NAME" '{task_id:$task_id,agent_name:$agent_name,action:"done",notes:"public tool sweep completed"}')")"
expect_ok "masc_transition done" "$r_done"

echo "PASS: public MCP tool live sweep"
