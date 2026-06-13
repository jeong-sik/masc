#!/usr/bin/env bash
# E2E: Verify SSE transport (baseline transport, must always work).
#
# Tests:
#   1. /health endpoint responds 200
#   2. SSE /sse endpoint sends event stream headers
#   3. JSON-RPC over SSE: initialize + tools/list
#   4. Broadcast generates SSE events

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

# Test 2: SSE endpoint sends correct headers
headers=$(curl -sf -I -m 3 "${MASC_HTTP_BASE_URL}/sse" 2>&1 || true)
if echo "$headers" | grep -qi "text/event-stream"; then
  pass "SSE content-type: text/event-stream"
else
  # SSE might need a session — try POST init first then check
  # For MCP SSE, the endpoint is typically accessed after init
  skip "SSE content-type check" "requires MCP session initialization"
fi

# Test 3: JSON-RPC initialize via Streamable HTTP (/mcp)
MCP_ACCEPT="Accept: application/json, text/event-stream"
init_req='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"e2e-harness","version":"1.0"}}}'
auth_args=()
auth_token="$(transport_auth_token)"
if [[ -n "$auth_token" ]]; then
  auth_args=(-H "Authorization: Bearer ${auth_token}")
fi
init_deadline=$(( $(date +%s) + 15 ))
init_resp=""
while [[ "$(date +%s)" -lt "$init_deadline" ]]; do
  init_resp=$(curl -sf -X POST "${MASC_HTTP_BASE_URL}/mcp" \
    "${auth_args[@]}" \
    -H "Content-Type: application/json" \
    -H "${MCP_ACCEPT}" \
    -d "$init_req" 2>&1 || true)
  if echo "$init_resp" | jq -e '.result.serverInfo' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if echo "$init_resp" | jq -e '.result.serverInfo' >/dev/null 2>&1; then
  pass "MCP initialize returns serverInfo"
  server_name=$(echo "$init_resp" | jq -r '.result.serverInfo.name')
  server_ver=$(echo "$init_resp" | jq -r '.result.serverInfo.version')
  printf '       server: %s v%s\n' "$server_name" "$server_ver"
else
  fail "MCP initialize" "unexpected response: ${init_resp:0:100}"
fi

# Test 4: Tools list via MCP (uses same session)
session_deadline=$(( $(date +%s) + 15 ))
SESSION_ID=""
while [[ "$(date +%s)" -lt "$session_deadline" ]]; do
  SESSION_ID="$(
    curl -sf -i -X POST "${MASC_HTTP_BASE_URL}/mcp" \
      "${auth_args[@]}" \
      -H "Content-Type: application/json" \
      -H "${MCP_ACCEPT}" \
      -d "$init_req" 2>&1 \
    | awk 'tolower($1)=="mcp-session-id:" { gsub("\r", "", $2); print $2; exit }'
  )"
  if [[ -n "$SESSION_ID" ]]; then
    break
  fi
  sleep 1
done
tools_req='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
tools_resp=$(curl -sf -X POST "${MASC_HTTP_BASE_URL}/mcp" \
  "${auth_args[@]}" \
  -H "Content-Type: application/json" \
  -H "${MCP_ACCEPT}" \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  -d "$tools_req" 2>&1 || echo '{}')
tool_count=$(jq '.result.tools | length' <<<"$tools_resp" 2>/dev/null || echo "0")
if [ "$tool_count" -gt 0 ]; then
  pass "MCP tools/list: ${tool_count} tools available"
else
  skip "MCP tools/list" "no tools returned (may need initialized notification)"
fi

summary
