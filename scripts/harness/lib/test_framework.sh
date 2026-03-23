#!/usr/bin/env bash
# Shared test framework for MCP contract harness scripts.
#
# Source this file after setting MCP_URL and other env vars.
# Depends on: jsonrpc_sse.sh (auto-sourced)

: "${MCP_URL:=http://127.0.0.1:8935/mcp}"
: "${CURL_RETRY_COUNT:=4}"
: "${CURL_RETRY_DELAY_SEC:=1}"
: "${CURL_TIMEOUT_SEC:=25}"
: "${MCP_SESSION_ID:=}"

_HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${_HARNESS_DIR}/jsonrpc_sse.sh"

# POST a JSON body to the MCP endpoint with retry logic.
# Includes mcp-session-id header when MCP_SESSION_ID is set.
# Usage: curl_post_mcp '{"jsonrpc":"2.0",...}'
curl_post_mcp() {
  local body="$1"
  local attempt=1
  local output=""
  while [ "$attempt" -le "$CURL_RETRY_COUNT" ]; do
    if [ -n "$MCP_SESSION_ID" ]; then
      output="$(curl -sS --http2-prior-knowledge -m "$CURL_TIMEOUT_SEC" -X POST "$MCP_URL" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -H "mcp-session-id: $MCP_SESSION_ID" \
        -d "$body" 2>/dev/null)" && {
          printf "%s" "$output"
          return 0
        }
    elif output="$(curl -sS --http2-prior-knowledge -m "$CURL_TIMEOUT_SEC" -X POST "$MCP_URL" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d "$body" 2>/dev/null)"; then
      printf "%s" "$output"
      return 0
    fi
    if [ "$attempt" -lt "$CURL_RETRY_COUNT" ]; then
      sleep "$CURL_RETRY_DELAY_SEC"
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

# Call an MCP tool and normalize SSE/JSON response.
# Usage: call_tool <jsonrpc_id> <tool_name> <args_json>
call_tool() {
  local id="$1"
  local name="$2"
  local args_json="$3"
  local raw
  raw="$(curl_post_mcp "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"tools/call\",\"params\":{\"name\":\"$name\",\"arguments\":$args_json}}")"
  jsonrpc_normalize_response "$raw" "$id"
}

# Extract .result from MCP tool response content.
# Usage: echo "$response" | extract_result
extract_result() {
  jq -c 'try (.result.content[0].text | fromjson | .result) catch empty'
}

# Extract .payload from MCP tool response content.
# Usage: echo "$response" | extract_payload
extract_payload() {
  jq -c 'try (.result.content[0].text | fromjson | .payload) catch empty'
}

# Extract error message from MCP tool response.
# Usage: echo "$response" | extract_error
extract_error() {
  jq -r 'try (.result.content[0].text | fromjson | .message) catch (.error.message // "")'
}

# Assert that a payload is valid JSON. Exits 1 on failure.
# Usage: require_ok "$response"
require_ok() {
  local payload="$1"
  if ! printf "%s" "$payload" | jq -e . >/dev/null 2>&1; then
    echo "FAIL: invalid json payload"
    printf "%s\n" "$payload"
    exit 1
  fi
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
