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

STEP=0

next_step() {
  STEP=$((STEP + 1))
  echo "[${STEP}] $1"
}

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

public_tool_manifest_exe="${PUBLIC_TOOL_MANIFEST_EXE:-${ROOT_DIR}/_build/default/bin/public_tool_manifest.exe}"
if [[ ! -x "$public_tool_manifest_exe" ]]; then
  echo "FAIL: public tool manifest executable not found: ${public_tool_manifest_exe}" >&2
  echo "Build ./bin/public_tool_manifest.exe before running the contract harness." >&2
  exit 1
fi

manifest_json="$(
  "$public_tool_manifest_exe" \
    | awk 'BEGIN { printing = 0 } /^\{/ { printing = 1 } printing { print }'
)"
expected_public_tools="$(printf '%s\n' "$manifest_json" | jq -c '.public_tool_names | sort')"

next_step "initialize MCP session"
initialize_mcp_session || {
  echo "FAIL: failed to initialize MCP session" >&2
  exit 1
}
if [[ -z "${MCP_SESSION_ID:-}" ]]; then
  echo "FAIL: empty MCP_SESSION_ID after initialize" >&2
  exit 1
fi

next_step "tools/list matches expected public surface"
tools_list_payload="$(call_method 5001 "tools/list" '{}')"
if ! response_transport_ok "$tools_list_payload"; then
  mcp_fail_with_context "tools/list failed" "$tools_list_payload"
fi
actual_public_tools="$(printf '%s' "$tools_list_payload" | jq -c '.result.tools | map(.name) | sort')"
if [[ "$actual_public_tools" != "$expected_public_tools" ]]; then
  diff_json="$(jq -cn --argjson expected "$expected_public_tools" --argjson actual "$actual_public_tools" '{expected:$expected,actual:$actual}')"
  mcp_fail_with_context "public tools/list surface drift" "$diff_json"
fi
board_reaction_emoji="$(
  printf '%s' "$tools_list_payload" \
    | jq -r '
      .result.tools[]
      | select(.name == "masc_board_reaction")
      | (.inputSchema // .input_schema)
      | .properties.emoji.enum[0] // empty
    ' \
    | head -n1
)"
if [[ -z "$board_reaction_emoji" ]]; then
  mcp_fail_with_context "masc_board_reaction schema missing emoji enum" "$tools_list_payload"
fi
echo "  PASS: tools/list public surface"

next_step "masc_start"
r_start="$(call_tool 5003 "masc_start" "$(jq -cn --arg path "$BASE_PATH" '{path:$path}')")"
expect_ok "masc_start" "$r_start"

next_step "masc_status"
r_status="$(call_tool 5004 "masc_status" '{}')"
expect_ok "masc_status" "$r_status"

next_step "masc_agent_card"
r_agent_card="$(call_tool 5005 "masc_agent_card" '{}')"
expect_ok "masc_agent_card" "$r_agent_card"

next_step "masc_tool_help"
r_tool_help="$(call_tool 5006 "masc_tool_help" '{"tool_name":"masc_status"}')"
expect_ok "masc_tool_help" "$r_tool_help"

next_step "masc_goal_list"
r_goal_list="$(call_tool 5008 "masc_goal_list" '{}')"
expect_ok "masc_goal_list" "$r_goal_list"

next_step "masc_goal_upsert"
GOAL_SEED_PAYLOAD="$(call_tool 5009 "masc_goal_upsert" '{"title":"Public Tool Sweep Goal","priority":1}')"
GOAL_ID="$(printf '%s' "$GOAL_SEED_PAYLOAD" | extract_result | jq -r '.goal_id // empty')"
if [ -z "$GOAL_ID" ]; then
  mcp_fail_with_context "could not create goal for public tool live sweep" "$GOAL_SEED_PAYLOAD"
fi
echo "  PASS: masc_goal_upsert"

next_step "masc_add_task"
r_add_task="$(call_tool 5010 "masc_add_task" "$(jq -cn --arg goal_id "$GOAL_ID" '{title:"Public Tool Sweep Task",goal_id:$goal_id,priority:2,description:"live public surface verification"}')")"
expect_ok "masc_add_task" "$r_add_task"
task_id="$(
  printf '%s' "$r_add_task" \
    | jq -r 'try (.result.structuredContent.task_id // .result.structuredContent.id) catch empty | strings' \
    | head -n1
)"
if [[ -z "$task_id" ]]; then
  mcp_fail_with_context "masc_add_task: could not extract task_id" "$r_add_task"
fi

next_step "masc_goal_transition"
r_goal_transition="$(
  call_tool 5011 "masc_goal_transition" "$(
    jq -cn \
      --arg goal_id "$GOAL_ID" \
      --arg actor "$AGENT_NAME" \
      '{goal_id:$goal_id,action:"pause",actor:{id:$actor},note:"public tool sweep pause"}'
  )"
)"
expect_ok "masc_goal_transition" "$r_goal_transition"

next_step "masc_goal_verify"
r_goal_verify="$(
  call_tool 5012 "masc_goal_verify" "$(
    jq -cn \
      --arg goal_id "$GOAL_ID" \
      --arg principal "$AGENT_NAME" \
      '{goal_id:$goal_id,principal:{id:$principal},decision:"approve",note:"public tool sweep guard vote"}'
  )"
)"
expect_ok_or_guard "masc_goal_verify" "$r_goal_verify" 'goal has no active verification request'

next_step "masc_batch_add_tasks"
r_batch_add="$(call_tool 5013 "masc_batch_add_tasks" "$(jq -cn --arg goal_id "$GOAL_ID" '{tasks:[{title:"Public Sweep Batch A",goal_id:$goal_id,priority:3,description:"batch-a"},{title:"Public Sweep Batch B",goal_id:$goal_id,priority:4,description:"batch-b"}]}')")"
expect_ok "masc_batch_add_tasks" "$r_batch_add"

next_step "masc_tasks"
r_tasks="$(call_tool 5014 "masc_tasks" '{}')"
expect_ok "masc_tasks" "$r_tasks"

next_step "masc_transition claim"
r_claim="$(call_tool 5015 "masc_transition" "$(jq -cn --arg task_id "$task_id" --arg agent_name "$AGENT_NAME" '{task_id:$task_id,agent_name:$agent_name,action:"claim",notes:"public tool sweep claim"}')")"
expect_ok_or_guard "masc_transition claim" "$r_claim" 'already claimed'

next_step "masc_plan_init"
r_plan_init="$(call_tool 5016 "masc_plan_init" "$(jq -cn --arg task_id "$task_id" '{task_id:$task_id}')")"
expect_ok "masc_plan_init" "$r_plan_init"

next_step "masc_plan_set_task"
r_plan_set="$(call_tool 5017 "masc_plan_set_task" "$(jq -cn --arg task_id "$task_id" '{task_id:$task_id}')")"
expect_ok "masc_plan_set_task" "$r_plan_set"

next_step "masc_check"
r_check="$(call_tool 5018 "masc_check" '{"assertions":["task_claimed","current_task_set"]}')"
expect_ok "masc_check" "$r_check"

next_step "masc_plan_update"
r_plan_update="$(call_tool 5019 "masc_plan_update" "$(jq -cn --arg task_id "$task_id" --arg content "public tool sweep plan" '{task_id:$task_id,content:$content}')")"
expect_ok "masc_plan_update" "$r_plan_update"

next_step "masc_plan_get"
r_plan_get="$(call_tool 5020 "masc_plan_get" "$(jq -cn --arg task_id "$task_id" '{task_id:$task_id}')")"
expect_ok "masc_plan_get" "$r_plan_get"

next_step "masc_transition start"
r_transition="$(call_tool 5021 "masc_transition" "$(jq -cn --arg task_id "$task_id" --arg agent_name "$AGENT_NAME" '{task_id:$task_id,agent_name:$agent_name,action:"start",notes:"public tool sweep start"}')")"
expect_ok "masc_transition start" "$r_transition"

next_step "masc_heartbeat"
r_heartbeat="$(call_tool 5022 "masc_heartbeat" '{}')"
expect_ok "masc_heartbeat" "$r_heartbeat"

next_step "masc_broadcast"
r_broadcast="$(call_tool 5023 "masc_broadcast" "$(jq -cn --arg agent_name "$AGENT_NAME" --arg message "public tool sweep broadcast" '{agent_name:$agent_name,message:$message}')")"
expect_ok "masc_broadcast" "$r_broadcast"

next_step "masc_messages"
r_messages="$(call_tool 5024 "masc_messages" '{}')"
expect_ok "masc_messages" "$r_messages"

next_step "masc_board_post"
r_board_post="$(call_tool 5025 "masc_board_post" "$(jq -cn --arg author "$AGENT_NAME" --arg title "Public Tool Sweep Post" --arg content "public tool sweep board post" '{author:$author,title:$title,content:$content,visibility:"internal"}')")"
expect_ok "masc_board_post" "$r_board_post"
post_id="$(
  printf '%s' "$r_board_post" \
    | jq -r 'try (.result.structuredContent.id) catch empty | strings' \
    | head -n1
)"
if [[ -z "$post_id" ]]; then
  mcp_fail_with_context "masc_board_post: could not extract post_id" "$r_board_post"
fi

next_step "masc_board_list"
r_board_list="$(call_tool 5026 "masc_board_list" '{"limit":5}')"
expect_ok "masc_board_list" "$r_board_list"

next_step "masc_board_post_get"
r_board_get="$(call_tool 5027 "masc_board_post_get" "$(jq -cn --arg post_id "$post_id" '{post_id:$post_id}')")"
expect_ok "masc_board_post_get" "$r_board_get"

next_step "masc_board_comment"
r_board_comment="$(call_tool 5028 "masc_board_comment" "$(jq -cn --arg post_id "$post_id" --arg author "$AGENT_NAME" --arg content "public tool sweep comment" '{post_id:$post_id,author:$author,content:$content}')")"
expect_ok "masc_board_comment" "$r_board_comment"
comment_id="$(
  printf '%s' "$r_board_comment" \
    | jq -r 'try (.result.structuredContent.comment_id // .result.structuredContent.id // .result.structuredContent.comment.id) catch empty | strings' \
    | head -n1
)"
if [[ -z "$comment_id" ]]; then
  mcp_fail_with_context "masc_board_comment: could not extract comment_id" "$r_board_comment"
fi

next_step "masc_board_vote"
r_board_vote="$(call_tool 5029 "masc_board_vote" "$(jq -cn --arg post_id "$post_id" --arg voter "$AGENT_NAME" '{post_id:$post_id,voter:$voter}')")"
expect_ok "masc_board_vote" "$r_board_vote"

next_step "masc_board_comment_vote"
if [[ -n "$comment_id" ]]; then
  r_comment_vote="$(call_tool 5030 "masc_board_comment_vote" "$(jq -cn --arg comment_id "$comment_id" --arg voter "$AGENT_NAME" '{comment_id:$comment_id,voter:$voter,direction:"up"}')")"
  expect_ok "masc_board_comment_vote" "$r_comment_vote"
else
  echo "  PASS: masc_board_comment_vote (skipped: comment id not present in comment response)"
fi

next_step "masc_board_reaction"
r_reaction="$(call_tool 5031 "masc_board_reaction" "$(jq -cn --arg post_id "$post_id" --arg user_id "$AGENT_NAME" --arg emoji "$board_reaction_emoji" '{target_type:"post",target_id:$post_id,user_id:$user_id,emoji:$emoji}')")"
expect_ok "masc_board_reaction" "$r_reaction"

next_step "masc_board_curation_read"
r_curation_read="$(call_tool 5032 "masc_board_curation_read" '{}')"
expect_ok "masc_board_curation_read" "$r_curation_read"

next_step "masc_board_curation_submit"
r_curation_submit="$(
  call_tool 5033 "masc_board_curation_submit" "$(
    jq -cn \
      --arg submitted_by "$AGENT_NAME" \
      --arg post_id "$post_id" \
      '{
        submitted_by:$submitted_by,
        summary:"Public tool sweep curation snapshot",
        ordering:[$post_id],
        highlights:[$post_id],
        health_score:0.5,
        rationale:"Contract harness verifies public curation submit routing.",
        provenance:{source:"public_tool_live_sweep"}
      }'
  )"
)"
expect_ok "masc_board_curation_submit" "$r_curation_submit"

next_step "masc_board_curation_read after submit"
r_curation_read_after="$(call_tool 5034 "masc_board_curation_read" '{}')"
expect_ok "masc_board_curation_read after submit" "$r_curation_read_after"

next_step "masc_persona_list"
r_persona_list="$(call_tool 5035 "masc_persona_list" '{}')"
expect_ok "masc_persona_list" "$r_persona_list"

next_step "masc_agent_timeline"
r_agent_timeline="$(call_tool 5036 "masc_agent_timeline" "$(jq -cn --arg agent_name "$AGENT_NAME" '{agent_name:$agent_name,limit:5}')")"
expect_ok "masc_agent_timeline" "$r_agent_timeline"

next_step "masc_transition done"
# RFC-0311 Phase 1: the completion gate requires a locally validated
# evidence_refs entry on done (notes and trace-shaped labels alone no longer
# satisfy it). Persist a base-path-local proof artifact and submit its relative
# path so the gate can resolve it deterministically.
evidence_ref=".masc/harness-evidence/public_tool_live_sweep.json"
evidence_path="${BASE_PATH}/${evidence_ref}"
mkdir -p "$(dirname "$evidence_path")"
jq -cn --arg session_id "$MCP_SESSION_ID" --arg agent_name "$AGENT_NAME" --arg task_id "$task_id" \
  '{harness:"public_tool_live_sweep",session_id:$session_id,agent_name:$agent_name,task_id:$task_id,status:"completed"}' \
  >"$evidence_path"
done_notes="Public MCP tool live sweep completed all requested tool calls and verified each response before task completion."
done_summary="public tool live sweep verified across the public MCP surface"
r_done="$(call_tool 5037 "masc_transition" "$(jq -cn --arg task_id "$task_id" --arg agent_name "$AGENT_NAME" --arg notes "$done_notes" --arg summary "$done_summary" --arg evidence_ref "$evidence_ref" '{task_id:$task_id,agent_name:$agent_name,action:"done",notes:$notes,handoff_context:{summary:$summary,evidence_refs:[$evidence_ref]}}')")"
expect_ok "masc_transition done" "$r_done"
CLEANUP_TASK_FINALIZED=1

echo "PASS: public MCP tool live sweep"
