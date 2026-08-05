#!/usr/bin/env bash
# E2E: Verify the current observer SSE and MCP HTTP surfaces.
#
# Tests:
#   1. /health endpoint responds 200
#   2. Authenticated observer /events endpoint sends event stream headers
#   3. Current JSON-RPC server/discover + tools/list

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/harness/transport/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck disable=SC2034
HARNESS_NAME="SSE"

require_server

# Test 1: Health check
echo "--- SSE Transport E2E ---"
if curl -sf "${MASC_HTTP_BASE_URL}/health" >/dev/null 2>&1; then
  pass "health endpoint responds"
else
  fail "health endpoint" "no response"
fi

# Test 2: Observer endpoint sends correct headers
auth_token="$(transport_auth_token)"
auth_file=""
headers_file="$(harness_mktemp_file "masc-observer-headers")"
if [[ -n "$auth_token" ]]; then
  auth_file="$(_mcp_auth_header_file "$auth_token")"
fi
curl_args=(-sS --max-time 2 -D "$headers_file" -o /dev/null)
if [[ -n "$auth_file" ]]; then
  curl_args+=(-H "@$auth_file")
fi
curl "${curl_args[@]}" \
  "${MASC_HTTP_BASE_URL}/events?session_id=transport-observer-$$" \
  >/dev/null 2>&1 || true
headers="$(<"$headers_file")"
rm -f "$headers_file"
if [[ -n "$auth_file" ]]; then
  rm -f "$auth_file"
fi
if grep -qi "text/event-stream" <<<"$headers"; then
  pass "SSE content-type: text/event-stream"
else
  fail "observer SSE content-type" "missing text/event-stream response"
fi

# Test 3: JSON-RPC discovery via Streamable HTTP (/mcp)
discover_resp="$(mcp_jsonrpc_call 1 "server/discover" '{}' "$auth_token" "$MCP_URL")"
if echo "$discover_resp" | jq -e '.result.resultType == "complete"' >/dev/null 2>&1; then
  pass "MCP server/discover returns complete result"
  server_name=$(echo "$discover_resp" | jq -r '.result._meta["io.modelcontextprotocol/serverInfo"].name')
  server_ver=$(echo "$discover_resp" | jq -r '.result._meta["io.modelcontextprotocol/serverInfo"].version')
  printf '       server: %s v%s\n' "$server_name" "$server_ver"
else
  fail "MCP server/discover" "unexpected response: ${discover_resp:0:100}"
fi

# Test 4: Stateless tools list via MCP
tools_resp="$(mcp_jsonrpc_call 2 "tools/list" '{}' "$auth_token" "$MCP_URL")"
tool_count=$(jq '.result.tools | length' <<<"$tools_resp" 2>/dev/null || echo "0")
if [ "$tool_count" -gt 0 ] && jq -e '.result.resultType == "complete"' <<<"$tools_resp" >/dev/null; then
  pass "MCP tools/list: ${tool_count} tools available"
else
  fail "MCP tools/list" "no complete tool list returned"
fi

summary
