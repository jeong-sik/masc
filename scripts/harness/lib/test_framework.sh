#!/usr/bin/env bash
# Shared test framework for MCP contract harness scripts.
#
# Source this file after setting MCP_URL and other env vars.
# Depends on: jsonrpc_sse.sh (auto-sourced)

: "${MCP_URL:=http://127.0.0.1:8935/mcp}"
: "${CURL_RETRY_COUNT:=4}"
: "${CURL_RETRY_DELAY_SEC:=1}"
: "${CURL_TIMEOUT_SEC:=25}"
: "${MCP_TOKEN:=}"

_HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/harness/jsonrpc_sse.sh
source "${_HARNESS_DIR}/jsonrpc_sse.sh"
# shellcheck source=scripts/harness/lib/mcp_jsonrpc.sh
source "${_HARNESS_DIR}/lib/mcp_jsonrpc.sh"

require_mcp_ready() {
  local payload
  payload="$(mcp_jsonrpc_call 0 "server/discover" '{}')"
  mcp_require_jsonrpc_ok "$payload" "server/discover" || return 1
  printf '%s' "$payload" | jq -e '.result.resultType == "complete"' >/dev/null
}

# Call an MCP tool and normalize SSE/JSON response.
# Usage: call_tool <jsonrpc_id> <tool_name> <args_json>
call_tool() {
  local id="$1"
  local name="$2"
  local args_json="$3"
  local raw
  raw="$(mcp_call_tool "$id" "$name" "$args_json")"
  printf '%s' "$raw"
}

extract_text() {
  jq -r 'if ._harness_error? then empty else try (.result.content[0].text) catch empty end'
}

# Extract .result from MCP tool response content.
# Usage: echo "$response" | extract_result
extract_result() {
  jq -c '
    if ._harness_error? then
      empty
    else
      try (
        .result.content[0].text
        | fromjson
        | if has("result") and .result != null then .result else . end
      ) catch empty
    end
  '
}

# Extract error message from MCP tool response.
# Usage: echo "$response" | extract_error
extract_error() {
  jq -r '
    if ._harness_error? then
      ._harness_error.message // ""
    else
      try (.result.content[0].text | fromjson | .message) catch (.error.message // "")
    end
  '
}

# Assert that a payload is valid JSON. Exits 1 on failure.
# Usage: require_ok "$response"
require_ok() {
  local payload="$1"
  mcp_require_tool_ok "$payload" "harness tool call"
}

# Print pass/fail summary line.
# Usage: test_summary <harness_name> <pass_count> <total_count>
test_summary() {
  local name="$1"
  local passed="$2"
  local total="$3"
  if [ "$passed" -eq "$total" ]; then
    echo "PASS: $name ($passed/$total)"
  else
    echo "FAIL: $name ($passed/$total)"
    return 1
  fi
}
