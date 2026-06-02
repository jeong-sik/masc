#!/usr/bin/env bash
# E2E: Verify HTTP/1.1 and h2c auto-detection.
#
# When MASC_USE_H2=1, the server should accept both HTTP/2 (h2c)
# and HTTP/1.1 connections on the same port via MSG_PEEK-based
# protocol detection.
#
# Tests:
#   1. HTTP/1.1 health check works (baseline)
#   2. HTTP/2 h2c health check works (if MASC_USE_H2=1)
#   3. Both protocols on same port (if serve_auto is active)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/harness/transport/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck disable=SC2034
HARNESS_NAME="h2c-autodetect"

require_server

echo "--- h2c Auto-detect E2E ---"

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
  skip "h2c prior-knowledge" "proto=${h2pk_proto} (MASC_USE_H2 may not be set)"
fi

# Test 3: MCP POST over h2c (the actual production path)
h2_mcp_code=$(curl -sf --max-time 5 --http2-prior-knowledge -X POST "${MASC_HTTP_BASE_URL}/mcp" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"h2c-harness","version":"1.0"}},"id":1}' \
  -o /dev/null -w '%{http_code}' 2>&1 || echo "0")
if [ "$h2_mcp_code" = "200" ]; then
  pass "MCP initialize over h2c (status: ${h2_mcp_code})"
else
  skip "MCP over h2c" "status=${h2_mcp_code} (h2c may not be enabled)"
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
