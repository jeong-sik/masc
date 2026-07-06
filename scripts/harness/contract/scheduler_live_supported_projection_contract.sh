#!/usr/bin/env bash
set -euo pipefail

: "${MCP_URL:=http://127.0.0.1:8935/mcp}"
: "${MCP_SESSION_ID:=}"
: "${SCHEDULER_LIVE_SUPPORTED_EXPECTED_STATUS:=}"
export MCP_SESSION_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/harness/lib/test_framework.sh
source "${SCRIPT_DIR}/../lib/test_framework.sh"

BASE_URL="${MCP_URL%/mcp}"
DASHBOARD_JSON="$(mcp_mktemp_file "masc-scheduler-live-supported-projection" ".json")"
AUTH_HEADER_FILE=""

cleanup() {
  rm -f "$DASHBOARD_JSON" "$AUTH_HEADER_FILE"
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

assert_projection_contract() {
  jq -e --arg expected_status "$SCHEDULER_LIVE_SUPPORTED_EXPECTED_STATUS" '
    def fail_contract($reason): error("scheduler_live_supported_projection_contract:" + $reason);
    def terminal_status:
      ["succeeded", "failed", "rejected", "cancelled", "expired"];
    def terminal_readiness:
      ["terminal", "expired"];
    def payload_support($row):
      $row.payload_support // "unknown";
    def execution_readiness($row):
      $row.execution_readiness // "";
    def stored_status($row):
      $row.status // "";
    def is_supported($row):
      payload_support($row) == "supported";
    def is_unsupported($row):
      payload_support($row) == "unsupported";
    def is_unknown($row):
      payload_support($row) == "unknown";
    def readiness_is_live($row):
      (terminal_readiness | index(execution_readiness($row)) | not);
    def status_is_non_terminal($row):
      (terminal_status | index(stored_status($row)) | not);

    .scheduled_automation as $automation
    | if ($automation | type) != "object"
      then fail_contract("missing_scheduled_automation")
      else .
      end
    | ($automation.live_supported_non_terminal_evidence // null) as $evidence
    | if ($evidence | type) != "object"
      then fail_contract("missing_live_supported_non_terminal_evidence")
      else .
      end
    | ($automation.requests // null) as $requests
    | if ($requests | type) != "array"
      then fail_contract("requests_not_array")
      else .
      end
    | if ($automation.truncated // false) == true
      then fail_contract("truncated_projection_cannot_prove_visible_row_counts")
      else .
      end
    | if (($automation.request_count // -1) != ($requests | length))
      then fail_contract("request_count_does_not_match_visible_rows")
      else .
      end
    | {
        request_count: ($requests | length),
        supported_request_count: ([$requests[] | select(is_supported(.))] | length),
        supported_non_terminal_count:
          ([$requests[] | select(is_supported(.) and status_is_non_terminal(.))] | length),
        supported_live_count:
          ([$requests[] | select(is_supported(.) and readiness_is_live(.))] | length),
        supported_terminal_or_expired_count:
          ([$requests[] | select(is_supported(.) and (readiness_is_live(.) | not))] | length),
        unsupported_request_count: ([$requests[] | select(is_unsupported(.))] | length),
        unknown_request_count: ([$requests[] | select(is_unknown(.))] | length),
        terminal_or_expired_count:
          ([$requests[] | select(readiness_is_live(.) | not)] | length),
        matched_supported_live_ids:
          ([$requests[] | select(is_supported(.) and readiness_is_live(.)) | .schedule_id])
      } as $counts
    | (if $counts.supported_live_count > 0
       then "matched_supported_non_terminal"
       elif $counts.supported_request_count == 0 and $counts.request_count > 0
       then "no_supported_payload_rows"
       else "no_supported_non_terminal"
       end) as $derived_status
    | if $evidence.schema != "masc.dashboard.scheduled_automation.live_supported_non_terminal_evidence.v1"
      then fail_contract("schema_mismatch")
      elif $evidence.source != "schedule_store"
      then fail_contract("source_mismatch")
      elif $evidence.criteria != "payload_support=supported && execution_readiness not in {terminal,expired}"
      then fail_contract("criteria_mismatch")
      elif $evidence.projection_status != $derived_status
      then fail_contract("projection_status_mismatch")
      elif ($expected_status != "" and $evidence.projection_status != $expected_status)
      then fail_contract("expected_projection_status_mismatch")
      elif $evidence.request_count != $counts.request_count
      then fail_contract("request_count_mismatch")
      elif $evidence.supported_request_count != $counts.supported_request_count
      then fail_contract("supported_request_count_mismatch")
      elif $evidence.supported_non_terminal_count != $counts.supported_non_terminal_count
      then fail_contract("supported_non_terminal_count_mismatch")
      elif $evidence.supported_live_count != $counts.supported_live_count
      then fail_contract("supported_live_count_mismatch")
      elif $evidence.supported_terminal_or_expired_count != $counts.supported_terminal_or_expired_count
      then fail_contract("supported_terminal_or_expired_count_mismatch")
      elif $evidence.unsupported_request_count != $counts.unsupported_request_count
      then fail_contract("unsupported_request_count_mismatch")
      elif $evidence.unknown_request_count != $counts.unknown_request_count
      then fail_contract("unknown_request_count_mismatch")
      elif $evidence.terminal_or_expired_count != $counts.terminal_or_expired_count
      then fail_contract("terminal_or_expired_count_mismatch")
      elif (($evidence.matched_schedule_ids // [])
            | all(. as $id | ($counts.matched_supported_live_ids | index($id)) != null)
            | not)
      then fail_contract("matched_schedule_ids_include_non_live_row")
      else
        {
          projection_status: $evidence.projection_status,
          request_count: $counts.request_count,
          supported_live_count: $counts.supported_live_count,
          unsupported_request_count: $counts.unsupported_request_count
        }
      end
  ' "$DASHBOARD_JSON"
}

echo "[1/2] dashboard tools exposes live supported projection contract"
curl_dashboard_tools
echo "  PASS: dashboard tools fetched"

echo "[2/2] projection evidence matches visible scheduler rows"
if ! assert_projection_contract; then
  mcp_fail_with_context \
    "dashboard live supported projection contract mismatch" \
    "$(jq -c '.scheduled_automation as $automation | {evidence:($automation.live_supported_non_terminal_evidence // null),request_count:($automation.request_count // null),truncated:($automation.truncated // null),requests:($automation.requests // [])}' "$DASHBOARD_JSON" 2>/dev/null || cat "$DASHBOARD_JSON")"
fi
echo "  PASS"

echo "PASS: scheduler live supported projection contract"
