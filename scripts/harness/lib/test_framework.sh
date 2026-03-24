#!/usr/bin/env bash
# Shared test framework for MCP contract harness scripts.
#
# Source this file after setting MCP_URL and other env vars.

: "${MCP_URL:=http://127.0.0.1:8935/mcp}"
: "${CURL_RETRY_COUNT:=4}"
: "${CURL_RETRY_DELAY_SEC:=1}"
: "${CURL_TIMEOUT_SEC:=25}"
: "${MCP_SESSION_ID:=}"

_HARNESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_HARNESS_LIB_DIR}/mcp_jsonrpc.sh"

# Contract harness validates MCP semantics, not h2c prior-knowledge support.
# Use normal HTTP negotiation here so the suite doesn't hang when the server
# speaks HTTP/1.1 on localhost.
MCP_CURL_EXTRA_ARGS="${MCP_CURL_EXTRA_ARGS:-}"

# Call an MCP tool and normalize SSE/JSON response.
# Usage: call_tool <jsonrpc_id> <tool_name> <args_json>
call_tool() {
  local id="$1"
  local name="$2"
  local args_json="$3"
  mcp_call_tool "$id" "$name" "$args_json"
}

extract_text() {
  mcp_extract_text
}

# Extract .result from MCP tool response content.
# Usage: echo "$response" | extract_result
extract_result() {
  mcp_extract_result
}

# Extract .payload from MCP tool response content.
# Usage: echo "$response" | extract_payload
extract_payload() {
  mcp_extract_payload
}

# Extract error message from MCP tool response.
# Usage: echo "$response" | extract_error
extract_error() {
  mcp_extract_error
}

# Assert that a payload is a successful tool response.
# Usage: require_ok "$response"
require_ok() {
  local payload="$1"
  mcp_require_tool_ok "$payload" "contract tool call"
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
