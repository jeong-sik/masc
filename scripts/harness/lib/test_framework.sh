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
export MCP_SESSION_ID

_HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/harness/jsonrpc_sse.sh
source "${_HARNESS_DIR}/jsonrpc_sse.sh"
# shellcheck source=scripts/harness/lib/mcp_jsonrpc.sh
source "${_HARNESS_DIR}/lib/mcp_jsonrpc.sh"

# Contract harness validates MCP semantics, not h2c prior-knowledge support.
# Use normal HTTP negotiation here so the suite doesn't hang when the server
# speaks HTTP/1.1 on localhost.
# POST a JSON body to the MCP endpoint with retry logic.
# Includes mcp-session-id header when MCP_SESSION_ID is set.
# Usage: curl_post_mcp '{"jsonrpc":"2.0",...}'
curl_post_mcp() {
  local body="$1"
  local attempt=1
  local output=""
  while [ "$attempt" -le "$CURL_RETRY_COUNT" ]; do
    if [ -n "$MCP_SESSION_ID" ]; then
      output="$(curl -sS -m "$CURL_TIMEOUT_SEC" -X POST "$MCP_URL" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -H "mcp-session-id: $MCP_SESSION_ID" \
        -d "$body" 2>/dev/null)" && {
          printf "%s" "$output"
          return 0
        }
    elif output="$(curl -sS -m "$CURL_TIMEOUT_SEC" -X POST "$MCP_URL" \
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

initialize_mcp_session() {
  local headers_file body_file
  headers_file="$(mcp_mktemp_file "masc-mcp-init-headers")"
  body_file="$(mcp_mktemp_file "masc-mcp-init-body")"

  if curl -sS -m "$CURL_TIMEOUT_SEC" -D "$headers_file" -o "$body_file" -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"contract-harness","version":"1.0"},"capabilities":{}}}' \
    >/dev/null 2>&1; then
    MCP_SESSION_ID="$(
      awk '
        tolower($0) ~ /^mcp-session-id:/ {
          sub(/^[^:]+:[[:space:]]*/, "", $0)
          sub(/\r$/, "", $0)
          print $0
          exit
        }
      ' "$headers_file"
    )"
    export MCP_SESSION_ID
    if [ -n "$MCP_SESSION_ID" ]; then
      curl -sS -m "$CURL_TIMEOUT_SEC" -X POST "$MCP_URL" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -H "mcp-session-id: $MCP_SESSION_ID" \
        -d '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
        >/dev/null 2>&1 || true
    fi
  fi

  rm -f "$headers_file" "$body_file"
  [ -n "$MCP_SESSION_ID" ]
}

ensure_mcp_session() {
  [ -n "$MCP_SESSION_ID" ] || initialize_mcp_session
}

# Call an MCP tool and normalize SSE/JSON response.
# Usage: call_tool <jsonrpc_id> <tool_name> <args_json>
call_tool() {
  local id="$1"
  local name="$2"
  local args_json="$3"
  local raw
  ensure_mcp_session
  raw="$(curl_post_mcp "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"tools/call\",\"params\":{\"name\":\"$name\",\"arguments\":$args_json}}")"
  jsonrpc_normalize_response "$raw" "$id"
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
