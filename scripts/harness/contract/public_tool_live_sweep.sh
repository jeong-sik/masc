#!/usr/bin/env bash
set -euo pipefail

: "${MCP_URL:=http://127.0.0.1:8935/mcp}"
: "${BASE_PATH:?BASE_PATH must be set by run_all.sh}"
: "${AGENT_NAME:=public-tool-sweep-harness}"
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

call_method() {
  local id="$1"
  local method="$2"
  local params_json="$3"
  local raw
  raw="$(curl_post_mcp "$(jq -cn --argjson id "$id" --arg method "$method" --argjson params "$params_json" '{jsonrpc:"2.0",id:$id,method:$method,params:$params}')")"
  jsonrpc_normalize_response "$raw" "$id"
}

CLEANUP_TASK_FINALIZED=0
# shellcheck disable=SC2329 # invoked by EXIT trap
cleanup_contract_task() {
  local exit_status=$?
  if [ "$CLEANUP_TASK_FINALIZED" -ne 1 ] && [ -n "${task_id:-}" ]; then
    call_tool 5999 "masc_transition" "$(jq -cn --arg task_id "$task_id" --arg agent_name "$AGENT_NAME" '{task_id:$task_id,agent_name:$agent_name,action:"cancel",notes:"public tool sweep cleanup after unsuccessful run"}')" >/dev/null 2>&1 || true
  fi
  exit "$exit_status"
}
trap 'cleanup_contract_task' EXIT

manifest_json="$(
  env -u DUNE_RPC MASC_STORAGE_TYPE=filesystem \
    opam exec -- dune exec --root "$ROOT_DIR" bin/public_tool_manifest.exe \
    | awk 'BEGIN { printing = 0 } /^\{/ { printing = 1 } printing { print }'
)"
expected_public_tools="$(printf '%s\n' "$manifest_json" | jq -c '.public_tool_names | sort')"

echo "[1/36] initialize MCP session"
initialize_mcp_session || {
  echo "FAIL: failed to initialize MCP session" >&2
  exit 1
}
if [[ -z "${MCP_SESSION_ID:-}" ]]; then
  echo "FAIL: empty MCP_SESSION_ID after initialize" >&2
  exit 1
fi

echo "[2/36] tools/list matches expected public surface"
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

echo "[3/36] masc_start"
r_start="$(call_tool 5003 "masc_start" "$(jq -cn --arg path "$BASE_PATH" '{path:$path}')")"
expect_ok "masc_start" "$r_start"

echo "[4/36] masc_status"
r_status="$(call_tool 5005 "masc_status" '{}')"
expect_ok "masc_status" "$r_status"

echo "[5/36] masc_dashboard"
r_dashboard="$(call_tool 5008 "masc_dashboard" '{}')"
expect_ok "masc_dashboard" "$r_dashboard"

echo "[6/36] masc_agent_card"
r_agent_card="$(call_tool 5009 "masc_agent_card" '{}')"
expect_ok "masc_agent_card" "$r_agent_card"

echo "[7/36] masc_agent_timeline"
r_agent_timeline="$(call_tool 5010 "masc_agent_timeline" "$(jq -cn --arg agent_name "$AGENT_NAME" '{agent_name:$agent_name,limit:5}')")"
expect_ok "masc_agent_timeline" "$r_agent_timeline"

echo "[8/36] masc_tool_help"
r_tool_help="$(call_tool 5012 "masc_tool_help" '{"tool_name":"masc_status"}')"
expect_ok "masc_tool_help" "$r_tool_help"

echo "[9/36] masc_goal_upsert"
GOAL_SEED_PAYLOAD="$(call_tool 5014 "masc_goal_upsert" "$(jq -cn --arg verifier "${AGENT_NAME}-verifier" '{title:"Public Tool Sweep Goal",priority:1,verifier_policy:{inherit_mode:"replace",principals:[{id:$verifier}],required_verdicts:1}}')")"
GOAL_ID="$(printf '%s' "$GOAL_SEED_PAYLOAD" | extract_result | jq -r '.goal_id // empty')"
if [ -z "$GOAL_ID" ]; then
  mcp_fail_with_context "could not create goal for public tool live sweep" "$GOAL_SEED_PAYLOAD"
fi
echo "  PASS: masc_goal_upsert"

echo "[10/36] masc_goal_list"
r_goal_list="$(call_tool 5013 "masc_goal_list" '{}')"
expect_ok "masc_goal_list" "$r_goal_list"

echo "[11/36] masc_add_task"
r_add_task="$(call_tool 5015 "masc_add_task" "$(jq -cn --arg goal_id "$GOAL_ID" '{title:"Public Tool Sweep Task",goal_id:$goal_id,priority:2,description:"live public surface verification"}')")"
expect_ok "masc_add_task" "$r_add_task"
task_id="$(
  printf '%s' "$r_add_task" \
    | jq -r 'try (.result.structuredContent.task_id // .result.structuredContent.id) catch empty | strings' \
    | head -n1
)"
if [[ -z "$task_id" ]]; then
  mcp_fail_with_context "masc_add_task: could not extract task_id" "$r_add_task"
fi

echo "[12/36] masc_batch_add_tasks"
r_batch_add="$(call_tool 5016 "masc_batch_add_tasks" "$(jq -cn --arg goal_id "$GOAL_ID" '{tasks:[{title:"Public Sweep Batch A",goal_id:$goal_id,priority:3,description:"batch-a"},{title:"Public Sweep Batch B",goal_id:$goal_id,priority:4,description:"batch-b"}]}')")"
expect_ok "masc_batch_add_tasks" "$r_batch_add"

echo "[13/36] masc_tasks"
r_tasks="$(call_tool 5017 "masc_tasks" '{}')"
expect_ok "masc_tasks" "$r_tasks"

echo "[14/36] masc_plan_init"
r_plan_init="$(call_tool 5018 "masc_plan_init" "$(jq -cn --arg task_id "$task_id" '{task_id:$task_id}')")"
expect_ok "masc_plan_init" "$r_plan_init"

echo "[15/36] masc_plan_set_task"
r_plan_set="$(call_tool 5019 "masc_plan_set_task" "$(jq -cn --arg task_id "$task_id" '{task_id:$task_id}')")"
expect_ok "masc_plan_set_task" "$r_plan_set"

echo "[16/36] masc_plan_update"
r_plan_update="$(call_tool 5020 "masc_plan_update" "$(jq -cn --arg task_id "$task_id" --arg content "public tool sweep plan" '{task_id:$task_id,content:$content}')")"
expect_ok "masc_plan_update" "$r_plan_update"

echo "[17/36] masc_plan_get"
r_plan_get="$(call_tool 5021 "masc_plan_get" "$(jq -cn --arg task_id "$task_id" '{task_id:$task_id}')")"
expect_ok "masc_plan_get" "$r_plan_get"

echo "[18/36] masc_transition (claim)"
r_claim="$(call_tool 5022 "masc_transition" "$(jq -cn --arg task_id "$task_id" --arg agent_name "$AGENT_NAME" '{task_id:$task_id,agent_name:$agent_name,action:"claim",notes:"public tool sweep claim"}')")"
expect_ok "masc_transition claim" "$r_claim"

echo "[19/36] masc_transition (start)"
r_transition="$(call_tool 5023 "masc_transition" "$(jq -cn --arg task_id "$task_id" --arg agent_name "$AGENT_NAME" '{task_id:$task_id,agent_name:$agent_name,action:"start",notes:"public tool sweep start"}')")"
expect_ok "masc_transition start" "$r_transition"

echo "[20/36] masc_check"
r_check="$(call_tool 5024 "masc_check" '{"assertions":["task_claimed","current_task_set"]}')"
expect_ok "masc_check" "$r_check"

echo "[21/36] masc_heartbeat"
r_heartbeat="$(call_tool 5025 "masc_heartbeat" '{}')"
expect_ok "masc_heartbeat" "$r_heartbeat"

echo "[22/36] masc_broadcast"
r_broadcast="$(call_tool 5026 "masc_broadcast" "$(jq -cn --arg agent_name "$AGENT_NAME" --arg message "public tool sweep broadcast" '{agent_name:$agent_name,message:$message}')")"
expect_ok "masc_broadcast" "$r_broadcast"

echo "[23/36] masc_messages"
r_messages="$(call_tool 5027 "masc_messages" '{}')"
expect_ok "masc_messages" "$r_messages"

echo "[24/36] masc_board_post"
r_board_post="$(call_tool 5028 "masc_board_post" "$(jq -cn --arg author "$AGENT_NAME" --arg title "Public Tool Sweep Post" --arg content "public tool sweep board post" '{author:$author,title:$title,content:$content,visibility:"internal"}')")"
expect_ok "masc_board_post" "$r_board_post"
post_id="$(
  printf '%s' "$r_board_post" \
    | jq -r 'try (.result.structuredContent.id) catch empty | strings' \
    | head -n1
)"
if [[ -z "$post_id" ]]; then
  mcp_fail_with_context "masc_board_post: could not extract post_id" "$r_board_post"
fi

echo "[25/36] masc_board_list"
r_board_list="$(call_tool 5029 "masc_board_list" '{"limit":5}')"
expect_ok "masc_board_list" "$r_board_list"

echo "[26/36] masc_board_post_get"
r_board_get="$(call_tool 5030 "masc_board_post_get" "$(jq -cn --arg post_id "$post_id" '{post_id:$post_id}')")"
expect_ok "masc_board_post_get" "$r_board_get"

echo "[27/36] masc_board_comment"
r_board_comment="$(call_tool 5031 "masc_board_comment" "$(jq -cn --arg post_id "$post_id" --arg author "$AGENT_NAME" --arg content "public tool sweep comment" '{post_id:$post_id,author:$author,content:$content}')")"
expect_ok "masc_board_comment" "$r_board_comment"
comment_id="$(
  printf '%s' "$r_board_comment" \
    | jq -r 'try (.result.structuredContent.comment_id // .result.structuredContent.id) catch empty | strings' \
    | head -n1
)"
if [[ -z "$comment_id" ]]; then
  mcp_fail_with_context "masc_board_comment: could not extract comment_id" "$r_board_comment"
fi

echo "[28/36] masc_board_vote"
r_board_vote="$(call_tool 5032 "masc_board_vote" "$(jq -cn --arg post_id "$post_id" --arg voter "$AGENT_NAME" '{post_id:$post_id,voter:$voter,direction:"up"}')")"
expect_ok "masc_board_vote" "$r_board_vote"

echo "[29/36] masc_board_comment_vote"
r_comment_vote="$(call_tool 5033 "masc_board_comment_vote" "$(jq -cn --arg comment_id "$comment_id" --arg voter "$AGENT_NAME" '{comment_id:$comment_id,voter:$voter,direction:"up"}')")"
expect_ok "masc_board_comment_vote" "$r_comment_vote"

echo "[30/36] masc_board_reaction"
r_reaction="$(call_tool 5034 "masc_board_reaction" "$(jq -cn --arg target_id "$post_id" --arg user_id "$AGENT_NAME" '{target_type:"post",target_id:$target_id,user_id:$user_id,emoji:"\uD83D\uDC4D"}')")"
expect_ok "masc_board_reaction" "$r_reaction"

echo "[31/36] masc_board_curation_read"
r_curation_read="$(call_tool 5035 "masc_board_curation_read" '{}')"
expect_ok "masc_board_curation_read" "$r_curation_read"

echo "[32/36] masc_board_curation_submit"
r_curation_submit="$(call_tool 5036 "masc_board_curation_submit" "$(jq -cn --arg submitted_by "$AGENT_NAME" --arg post_id "$post_id" '{submitted_by:$submitted_by,summary:"public sweep curation",ordering:[$post_id],highlights:[$post_id],health_score:1.0,rationale:"public tool sweep curation"}')")"
expect_ok "masc_board_curation_submit" "$r_curation_submit"

echo "[33/36] masc_persona_list"
r_persona_list="$(call_tool 5037 "masc_persona_list" '{"detailed":false}')"
expect_ok "masc_persona_list" "$r_persona_list"

echo "[34/36] masc_goal_transition"
r_goal_transition="$(call_tool 5038 "masc_goal_transition" "$(jq -cn --arg goal_id "$GOAL_ID" --arg actor "$AGENT_NAME" '{goal_id:$goal_id,action:"request_complete",actor:{id:$actor},note:"public sweep verification request"}')")"
expect_ok "masc_goal_transition" "$r_goal_transition"

echo "[35/36] masc_goal_verify"
r_goal_verify="$(call_tool 5039 "masc_goal_verify" "$(jq -cn --arg goal_id "$GOAL_ID" --arg principal "${AGENT_NAME}-verifier" '{goal_id:$goal_id,principal:{id:$principal},decision:"approve",note:"public sweep verifier approval"}')")"
expect_ok "masc_goal_verify" "$r_goal_verify"

echo "[36/36] masc_transition (done)"
r_done="$(call_tool 5040 "masc_transition" "$(jq -cn --arg task_id "$task_id" --arg agent_name "$AGENT_NAME" '{task_id:$task_id,agent_name:$agent_name,action:"done",notes:"public tool sweep done"}')")"
expect_ok "masc_transition done" "$r_done"
CLEANUP_TASK_FINALIZED=1

echo "PASS: public MCP tool live sweep"
