#!/usr/bin/env bash
# Golden Path 1 Contract — Core workspace collaboration e2e verification.
#
# Tests the fundamental 13-step MASC workflow:
#   producer join → add_task → claim → plan_set_task → heartbeat → broadcast
#   → status → direct-done rejection → submit_for_verification
#   → verifier join → verifier claim → verifier approve → final projection
#
# This is the minimum viable path that must always work.
# If this contract fails, MASC workspace collaboration is broken.
#
# Usage:
#   MCP_URL=http://127.0.0.1:8935/mcp MCP_TOKEN=... \
#     MCP_VERIFIER_TOKEN=... ./golden_path_1_contract.sh
set -euo pipefail

AGENT_NAME="${AGENT_NAME:-${MCP_AGENT_NAME:-golden-path-1-harness}}"
VERIFIER_AGENT_NAME="${MCP_VERIFIER_AGENT_NAME:-contract-harness-verifier}"
MCP_VERIFIER_TOKEN="${MCP_VERIFIER_TOKEN:-}"
PRODUCER_MCP_TOKEN="${MCP_TOKEN:-}"
MCP_SESSION_ID="${MCP_SESSION_ID:-}"
PRODUCER_MCP_SESSION_ID=""
export MCP_SESSION_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/test_framework.sh"

PASS=0
FAIL=0
GOAL_ID=""
CLEANUP_TASK_FINALIZED=0
START_PATH="${BASE_PATH:-$PWD}"

# shellcheck disable=SC2329 # invoked by EXIT trap
cleanup_contract_task() {
  local exit_status=$?
  if [ "$CLEANUP_TASK_FINALIZED" -ne 1 ] && [ -n "${task_id:-}" ]; then
    MCP_TOKEN="$PRODUCER_MCP_TOKEN"
    MCP_SESSION_ID="$PRODUCER_MCP_SESSION_ID"
    export MCP_TOKEN MCP_SESSION_ID
    call_tool 1999 "masc_transition" "$(jq -cn --arg task_id "$task_id" --arg agent_name "$AGENT_NAME" '{task_id:$task_id,agent_name:$agent_name,action:"cancel",notes:"GP1 contract cleanup after unsuccessful run"}')" >/dev/null 2>&1 || true
  fi
  exit "$exit_status"
}
trap 'cleanup_contract_task' EXIT

initialize_mcp_session || {
  echo "FAIL: failed to initialize MCP session" >&2
  exit 1
}
if [ -z "${MCP_SESSION_ID:-}" ]; then
  echo "FAIL: empty MCP_SESSION_ID after initialize" >&2
  exit 1
fi
PRODUCER_MCP_SESSION_ID="$MCP_SESSION_ID"
if [ -z "$MCP_VERIFIER_TOKEN" ]; then
  echo "FAIL: MCP_VERIFIER_TOKEN is required for the distinct verifier session" >&2
  exit 1
fi
if [ "$VERIFIER_AGENT_NAME" = "$AGENT_NAME" ]; then
  echo "FAIL: verifier agent must be distinct from producer agent" >&2
  exit 1
fi

ensure_contract_goal() {
  local goal_payload
  local goal_json

  goal_payload="$(call_tool 1000 "masc_goal_upsert" '{"title":"GP1 contract goal","priority":1}')"
  goal_json="$(printf '%s' "$goal_payload" | extract_result)"
  GOAL_ID="$(printf '%s' "$goal_json" | jq -r '.goal_id // empty')"
  if [ -z "$GOAL_ID" ]; then
    mcp_fail_with_context "could not create goal for contract goal_id" "$goal_payload"
  fi
}

step_pass() { PASS=$((PASS + 1)); echo "  PASS"; }
step_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# ── Step 1/13: start / bind producer session ──
echo "[1/13] masc_start (producer)"
r1="$(call_tool 1001 "masc_start" "$(jq -cn --arg path "$START_PATH" '{path:$path}')")"
if require_ok "$r1"; then
  step_pass
else
  step_fail "masc_start rejected"
  echo "$r1"
  exit 1
fi
if [ -z "${MCP_SESSION_ID:-}" ]; then
  step_fail "empty MCP_SESSION_ID after masc_start"
  exit 1
fi

ensure_contract_goal

# ── Step 2/13: add_task ──
echo "[2/13] masc_add_task"
task_title="GP1 contract task $(date +%s)"
r2="$(call_tool 1002 "masc_add_task" "$(jq -cn --arg goal_id "$GOAL_ID" --arg task_title "$task_title" '{title: $task_title, goal_id: $goal_id, priority: 2, description: "Automated golden path 1 contract verification"}')")"
if require_ok "$r2"; then
  step_pass
else
  step_fail "add_task failed"
  echo "$r2"
  exit 1
fi
task_json="$(printf '%s' "$r2" | extract_result)"
task_id="$(printf '%s' "$task_json" | jq -r '.task_id // .id // empty')"
if [ -z "$task_id" ]; then
  step_fail "could not extract task_id from add_task response"
  echo "$r2"
  exit 1
fi
echo "  task_id=$task_id"

# ── Step 3/13: claim ──
echo "[3/13] masc_transition (producer claim)"
r3="$(call_tool 1003 "masc_transition" "{\"task_id\":\"$task_id\",\"agent_name\":\"$AGENT_NAME\",\"action\":\"claim\",\"notes\":\"GP1 contract claim\"}")"
if require_ok "$r3"; then
  step_pass
else
  step_fail "claim failed"
  echo "$r3"
  exit 1
fi

# ── Step 4/13: plan_set_task ──
echo "[4/13] masc_plan_set_task"
r4="$(call_tool 1004 "masc_plan_set_task" "{\"task_id\":\"$task_id\"}")"
if require_ok "$r4"; then
  step_pass
else
  step_fail "plan_set_task failed"
  echo "$r4"
fi

# ── Step 5/13: heartbeat ──
echo "[5/13] masc_heartbeat"
r5="$(call_tool 1005 "masc_heartbeat" "{}")"
if require_ok "$r5"; then
  step_pass
else
  step_fail "heartbeat failed"
  echo "$r5"
fi

# ── Step 6/13: broadcast ──
echo "[6/13] masc_broadcast"
r6="$(call_tool 1006 "masc_broadcast" "$(jq -cn --arg agent_name "$AGENT_NAME" --arg message "GP1 contract verification in progress" '{agent_name:$agent_name,message:$message}')")"
if require_ok "$r6"; then
  step_pass
else
  step_fail "broadcast failed"
  echo "$r6"
fi

# ── Step 7/13: status ──
echo "[7/13] masc_status"
r7="$(call_tool 1007 "masc_status" "{}")"
if require_ok "$r7"; then
  step_pass
else
  step_fail "status failed"
  echo "$r7"
fi

# ── Step 8/13: direct done must remain rejected ──
echo "[8/13] masc_transition (direct done rejection)"
evidence_ref="note:GP1 contract live MCP transcript verified by producer ${AGENT_NAME}"
done_notes="Completed GP1 contract flow: bound workspace, created and claimed task, set current task, sent heartbeat, broadcast progress, and verified masc_status returned success."
done_summary="GP1 contract flow verified end to end via live MCP transcript"
r8="$(call_tool 1008 "masc_transition" "$(jq -cn --arg task_id "$task_id" --arg agent_name "$AGENT_NAME" --arg notes "$done_notes" --arg summary "$done_summary" --arg evidence_ref "$evidence_ref" '{task_id:$task_id,agent_name:$agent_name,action:"done",notes:$notes,handoff_context:{summary:$summary,evidence_refs:[$evidence_ref]}}')")"
direct_done_error="$(printf '%s' "$r8" | extract_error)"
if require_ok "$r8" >/dev/null 2>&1; then
  step_fail "direct done unexpectedly succeeded"
  echo "$r8"
elif [[ "$direct_done_error" == *"must be submitted for verification"* ]]; then
  step_pass
else
  step_fail "direct done rejection contract changed"
  echo "$r8"
fi

# ── Step 9/13: producer submits typed evidence for verification ──
echo "[9/13] masc_transition (submit_for_verification)"
r9="$(call_tool 1009 "masc_transition" "$(jq -cn --arg task_id "$task_id" --arg agent_name "$AGENT_NAME" --arg notes "$done_notes" --arg summary "$done_summary" --arg evidence_ref "$evidence_ref" '{task_id:$task_id,agent_name:$agent_name,action:"submit_for_verification",notes:$notes,handoff_context:{summary:$summary,evidence_refs:[$evidence_ref]}}')")"
if require_ok "$r9"; then
  step_pass
else
  step_fail "submit_for_verification failed"
  echo "$r9"
fi

# ── Step 10/13: initialize and bind a distinct verifier session ──
echo "[10/13] masc_start (distinct verifier)"
MCP_TOKEN="$MCP_VERIFIER_TOKEN"
MCP_SESSION_ID=""
export MCP_TOKEN MCP_SESSION_ID
if ! initialize_mcp_session; then
  step_fail "verifier MCP session initialization failed"
  exit 1
fi
if [ -z "${MCP_SESSION_ID:-}" ] || [ "$MCP_SESSION_ID" = "$PRODUCER_MCP_SESSION_ID" ]; then
  step_fail "verifier MCP session is not distinct"
  exit 1
fi
r10="$(call_tool 1010 "masc_start" "$(jq -cn --arg path "$START_PATH" '{path:$path}')")"
if require_ok "$r10"; then
  step_pass
else
  step_fail "verifier masc_start rejected"
  echo "$r10"
  exit 1
fi

# ── Step 11/13: assigned verifier claims AwaitingVerification task ──
echo "[11/13] masc_transition (verifier claim)"
r11="$(call_tool 1011 "masc_transition" "$(jq -cn --arg task_id "$task_id" --arg agent_name "$VERIFIER_AGENT_NAME" '{task_id:$task_id,agent_name:$agent_name,action:"claim",notes:"GP1 verifier claims AwaitingVerification task"}')")"
if require_ok "$r11"; then
  step_pass
else
  step_fail "verifier claim failed"
  echo "$r11"
fi

# ── Step 12/13: only the assigned verifier approves ──
echo "[12/13] masc_transition (verifier approve)"
r12="$(call_tool 1012 "masc_transition" "$(jq -cn --arg task_id "$task_id" --arg agent_name "$VERIFIER_AGENT_NAME" '{task_id:$task_id,agent_name:$agent_name,action:"approve",notes:"GP1 verifier approved typed producer evidence"}')")"
if require_ok "$r12"; then
  CLEANUP_TASK_FINALIZED=1
  step_pass
else
  step_fail "verifier approval failed"
  echo "$r12"
fi

# ── Step 13/13: final task is Done and remains credited to producer ──
echo "[13/13] masc_tasks (Done producer credit)"
r13="$(call_tool 1013 "masc_tasks" '{"include_done":true,"status":"done"}')"
final_result="$(printf '%s' "$r13" | extract_result)"
final_text="$(printf '%s' "$final_result" | jq -r 'if type == "string" then . else tostring end' 2>/dev/null || true)"
if require_ok "$r13" \
  && [[ "$final_text" == *"$task_id"* ]] \
  && [[ "${final_text,,}" == *"done"* ]] \
  && [[ "$final_text" == *"$AGENT_NAME"* ]]; then
  step_pass
else
  step_fail "final Done projection did not retain producer credit"
  echo "$r13"
fi

# ── Summary ──
echo ""
echo "=== Golden Path 1 Contract ==="
echo "  PASS: $PASS / 13"
echo "  FAIL: $FAIL / 13"
if [ "$FAIL" -gt 0 ]; then
  echo "  STATUS: BROKEN"
  exit 1
else
  echo "  STATUS: GREEN"
  exit 0
fi
