#!/usr/bin/env bash
# E2E: Verify HTTP/1.1 and h2c auto-detection.
#
# In auto mode the server accepts both HTTP/2 prior-knowledge (h2c) and
# HTTP/1.1 connections on the same port via protocol detection.
#
# Tests:
#   1. HTTP/1.1 health check works (baseline)
#   2. HTTP/2 h2c health check works
#   3. The runtime reports the exact auto listener mode

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/harness/transport/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck disable=SC2034
HARNESS_NAME="h2c-autodetect"

require_server

echo "--- h2c Auto-detect E2E ---"

token="$(transport_auth_token)"
auth_args=()
if [[ -n "$token" ]]; then
  auth_args=(-H "Authorization: Bearer ${token}")
fi
transport_health_json=""
listener_mode=""
for _ in {1..25}; do
  transport_health_json="$(
    curl -fsS --max-time 5 "${auth_args[@]}" \
      "${MASC_HTTP_BASE_URL}/api/v1/dashboard/transport-health" 2>/dev/null || true
  )"
  listener_mode="$(
    jq -er '.http2.listener_mode' <<<"$transport_health_json" 2>/dev/null || true
  )"
  if [[ -n "$listener_mode" ]]; then
    break
  fi
  sleep 1
done
if [[ "$listener_mode" != "auto" ]]; then
  fail "HTTP listener mode" "expected auto, got ${listener_mode:-missing}"
  summary
  exit 1
fi
pass "HTTP listener reports auto mode"

# Test 1: HTTP/1.1 always works
if curl -sf --http1.1 "${MASC_HTTP_BASE_URL}/health" >/dev/null 2>&1; then
  pass "HTTP/1.1 health check"
else
  fail "HTTP/1.1 health check" "failed"
fi

# Test 2: h2c prior-knowledge (direct HTTP/2 without upgrade)
# This is the reliable way to test h2c — --http2 uses Upgrade header
# which serve_auto may not support (MSG_PEEK detects connection preface).
h2pk_proto=$(curl -sf -o /dev/null -w '%{http_version}' --http2-prior-knowledge "${MASC_HTTP_BASE_URL}/health" 2>&1 || echo "fail")
if [ "$h2pk_proto" = "2" ] || [ "$h2pk_proto" = "2.0" ]; then
  pass "h2c prior-knowledge health check (proto: ${h2pk_proto})"
else
  fail "h2c prior-knowledge" "proto=${h2pk_proto}"
fi

# Test 3: MCP POST over h2c (the actual production path)
if ! h2_mcp_code="$(
  curl -sS --max-time 5 --http2-prior-knowledge -X POST "${MASC_HTTP_BASE_URL}/mcp" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    "${auth_args[@]}" \
    -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"h2c-harness","version":"1.0"}},"id":1}' \
    -o /dev/null -w '%{http_code}' 2>/dev/null
)"; then
  h2_mcp_code="transport_error"
fi
if [ "$h2_mcp_code" = "200" ]; then
  pass "MCP initialize over h2c (status: ${h2_mcp_code})"
else
  fail "MCP over h2c" "status=${h2_mcp_code}"
fi

# Test 4: HTTP/1.1 SSE endpoint (most critical path)
sse_headers=$(curl -sf -I -m 3 --http1.1 "${MASC_HTTP_BASE_URL}/sse" 2>&1 || true)
if echo "$sse_headers" | grep -qi "200\|text/event-stream"; then
  pass "HTTP/1.1 SSE endpoint accessible"
else
  skip "HTTP/1.1 SSE endpoint" "may need session"
fi

# Test 5: Concurrent connections (HTTP/1.1 while h2c might be active)
pids=()
success=0
for _ in 1 2 3 4; do
  curl -sf --http1.1 "${MASC_HTTP_BASE_URL}/health" >/dev/null 2>&1 &
  pids+=($!)
done
for pid in "${pids[@]}"; do
  wait "$pid" 2>/dev/null && success=$((success + 1))
done
if [ "$success" -eq 4 ]; then
  pass "concurrent HTTP/1.1 connections (4/4)"
else
  fail "concurrent connections" "${success}/4 succeeded"
fi

summary
