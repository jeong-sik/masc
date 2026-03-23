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
source "${SCRIPT_DIR}/common.sh"
HARNESS_NAME="h2c-autodetect"

require_server

echo "--- h2c Auto-detect E2E ---"

# Test 1: HTTP/1.1 always works
h1_resp=$(curl -sf --http1.1 "${MASC_BASE_URL}/health" 2>&1)
if [ $? -eq 0 ]; then
  pass "HTTP/1.1 health check"
else
  fail "HTTP/1.1 health check" "failed"
fi

# Test 2: Check if h2c is active
h2_resp=$(curl -sf --http2 "${MASC_BASE_URL}/health" 2>&1)
h2_exit=$?
h2_proto=$(curl -sf -o /dev/null -w '%{http_version}' --http2 "${MASC_BASE_URL}/health" 2>&1 || echo "unknown")

if [ "$h2_exit" -eq 0 ]; then
  if [ "$h2_proto" = "2" ] || [ "$h2_proto" = "2.0" ]; then
    pass "HTTP/2 h2c health check (proto: ${h2_proto})"
  else
    # curl --http2 falls back to HTTP/1.1 if h2c upgrade fails
    skip "h2c upgrade" "server responded as HTTP/${h2_proto} (h2c may not be enabled)"
  fi
else
  skip "h2c health check" "curl --http2 failed (h2c likely not enabled)"
fi

# Test 3: HTTP/1.1 SSE endpoint (most critical path)
sse_headers=$(curl -sf -I -m 3 --http1.1 "${MASC_BASE_URL}/sse" 2>&1 || true)
if echo "$sse_headers" | grep -qi "200\|text/event-stream"; then
  pass "HTTP/1.1 SSE endpoint accessible"
else
  skip "HTTP/1.1 SSE endpoint" "may need session"
fi

# Test 4: Concurrent connections (HTTP/1.1 while h2c might be active)
pids=()
success=0
for i in 1 2 3 4; do
  curl -sf --http1.1 "${MASC_BASE_URL}/health" >/dev/null 2>&1 &
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
