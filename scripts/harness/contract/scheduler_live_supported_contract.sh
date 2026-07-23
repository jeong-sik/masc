#!/usr/bin/env bash
set -euo pipefail

: "${MCP_URL:=http://127.0.0.1:8935/mcp}"
: "${BASE_PATH:?BASE_PATH must be set by run_all.sh}"
: "${AGENT_NAME:=${MCP_AGENT_NAME:-scheduler-live-supported-harness}}"
: "${MCP_SESSION_ID:=}"
export MCP_SESSION_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/harness/lib/test_framework.sh
source "${SCRIPT_DIR}/../lib/test_framework.sh"

BASE_URL="${MCP_URL%/mcp}"
SCHEDULE_ID="contract-live-supported-$$"
KEEPER_NAME="contract-scheduler-keeper"
NOW_UNIX="$(date +%s)"
DUE_AT_UNIX="$((NOW_UNIX + 3600))"
DASHBOARD_JSON="$(mcp_mktemp_file "masc-scheduler-live-supported-dashboard" ".json")"
AUTH_HEADER_FILE=""
CREATED_SCHEDULE_ID=""

canonical_base="$(cd "$BASE_PATH" && pwd -P)"
canonical_tmp_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
case "$canonical_base" in
  "$canonical_tmp_root"/*) ;;
  *)
    if [[ "${SCHEDULER_LIVE_SUPPORTED_ALLOW_PERSISTENT_BASE:-0}" != "1" ]]; then
      echo \
        "FAIL: scheduler live supported contract refuses non-temp BASE_PATH=${canonical_base}" \
        >&2
      echo \
        "Set SCHEDULER_LIVE_SUPPORTED_ALLOW_PERSISTENT_BASE=1 only for an intentional persistent-base run." \
        >&2
      exit 1
    fi
    ;;
esac

cleanup() {
  local status=$?
  local cleanup_status=0
  if [[ -n "${CREATED_SCHEDULE_ID:-}" ]]; then
    local cancel_payload cancel_response cancel_status ok_status
    cancel_payload="$(
      jq -cn \
        --arg schedule_id "$CREATED_SCHEDULE_ID" \
        --arg cancelled_by_id "contract-scheduler" \
        --arg reason "contract harness cleanup" \
        '{
          schedule_id: $schedule_id,
          cancelled_by_id: $cancelled_by_id,
          reason: $reason
        }'
    )"
    set +e
    cancel_response="$(call_tool 6102 "masc_schedule_cancel" "$cancel_payload" 2>&1)"
    cancel_status=$?
    if [[ "$cancel_status" -eq 0 ]]; then
      require_ok "$cancel_response"
      ok_status=$?
    else
      ok_status=$cancel_status
    fi
    set -e
    if [[ "$ok_status" -ne 0 ]]; then
      cleanup_status=1
      echo "FAIL: failed to cancel schedule created by contract harness: ${CREATED_SCHEDULE_ID}" >&2
      printf '%s\n' "$cancel_response" >&2
    fi
  fi
  rm -f "$DASHBOARD_JSON" "$AUTH_HEADER_FILE"
  if [[ "$status" -eq 0 && "$cleanup_status" -ne 0 ]]; then
    exit "$cleanup_status"
  fi
  exit "$status"
}
trap cleanup EXIT

auth_token="$(mcp_default_auth_token)"
if [[ -n "$auth_token" ]]; then
  AUTH_HEADER_FILE="$(_mcp_auth_header_file "$auth_token")"
fi

curl_dashboard_tools() {
  local -a headers=()
  if [[ -n "$AUTH_HEADER_FILE" ]]; then
    headers+=( -H "@$AUTH_HEADER_FILE" )
  fi
  curl -fsS --max-time "${CURL_TIMEOUT_SEC:-25}" "${headers[@]}" \
    "${BASE_URL}/api/v1/dashboard/tools" >"$DASHBOARD_JSON"
}

assert_dashboard_matched_supported_non_terminal() {
  local schedule_id="$1"
  jq -e --arg schedule_id "$schedule_id" '
    .scheduled_automation as $automation
    | ($automation.live_supported_non_terminal_evidence // {}) as $evidence
    | ($automation.requests // []) as $requests
    | ($requests[] | select(.schedule_id == $schedule_id)) as $row
    | $evidence.schema == "masc.dashboard.scheduled_automation.live_supported_non_terminal_evidence.v1"
      and $evidence.source == "schedule_store"
      and $evidence.projection_status == "matched_supported_non_terminal"
      and $evidence.criteria == "payload_support=supported && status is non-terminal"
      and ($evidence.supported_request_count >= 1)
      and ($evidence.supported_non_terminal_count >= 1)
      and ($evidence.supported_live_count >= 1)
      and (($evidence.matched_schedule_ids // []) | index($schedule_id) != null)
      and $row.payload_kind == "masc.keeper_wake"
      and $row.payload_support == "supported"
      and (($row.status | IN("succeeded", "failed", "cancelled", "expired")) | not)
  ' "$DASHBOARD_JSON" >/dev/null
}

echo "[1/3] initialize MCP session"
initialize_mcp_session || {
  echo "FAIL: failed to initialize MCP session" >&2
  exit 1
}
if [[ -z "${MCP_SESSION_ID:-}" ]]; then
  echo "FAIL: empty MCP_SESSION_ID after initialize" >&2
  exit 1
fi
echo "  PASS"

echo "[2/3] create supported masc.keeper_wake schedule through MCP tool"
create_payload="$(
  jq -cn \
    --arg schedule_id "$SCHEDULE_ID" \
    --arg keeper_name "$KEEPER_NAME" \
    --arg message "Contract harness live supported scheduler evidence." \
    --argjson requested_at "$NOW_UNIX" \
    --argjson due_at "$DUE_AT_UNIX" \
    '{
      schedule_id: $schedule_id,
      requested_at_unix: $requested_at,
      due_at_unix: $due_at,
      requested_by_id: "contract-operator",
      scheduled_by_id: "contract-scheduler",
      payload_kind: "masc.keeper_wake",
      payload_body: {
        keeper_name: $keeper_name,
        title: "Contract scheduler evidence",
        message: $message,
        urgency: "normal"
      }
    }'
)"
create_response="$(call_tool 6101 "masc_schedule_create" "$create_payload")"
require_ok "$create_response"
created_schedule_id="$(
  printf '%s' "$create_response" \
    | extract_result \
    | jq -r '.schedule_id // empty'
)"
if [[ -n "$created_schedule_id" ]]; then
  CREATED_SCHEDULE_ID="$created_schedule_id"
fi
if [[ "$created_schedule_id" != "$SCHEDULE_ID" ]]; then
  mcp_fail_with_context \
    "masc_schedule_create returned unexpected schedule_id" \
    "$(jq -cn --arg expected "$SCHEDULE_ID" --arg actual "$created_schedule_id" '{expected:$expected,actual:$actual}')"
fi
echo "  PASS: ${SCHEDULE_ID}"

echo "[3/3] dashboard tools reports matched_supported_non_terminal"
curl_dashboard_tools
if ! assert_dashboard_matched_supported_non_terminal "$SCHEDULE_ID"; then
  mcp_fail_with_context \
    "dashboard scheduled automation did not prove matched_supported_non_terminal" \
    "$(jq -c '.scheduled_automation.live_supported_non_terminal_evidence as $evidence | {evidence:$evidence,requests:(.scheduled_automation.requests // [])}' "$DASHBOARD_JSON" 2>/dev/null || cat "$DASHBOARD_JSON")"
fi
echo "  PASS: ${SCHEDULE_ID}"

echo "PASS: scheduler live supported contract"
