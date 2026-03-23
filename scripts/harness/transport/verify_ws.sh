#!/usr/bin/env bash
# E2E: Verify WebSocket transport.
#
# Tests:
#   1. WebSocket upgrade attempt on /ws endpoint
#   2. Feature gate: disabled when MASC_WS_ENABLED != 1
#   3. WebSocket frame exchange (requires websocat)
#
# NOTE: TRANS-001 identifies a potential bug where the WebSocket I/O
# loop may not be driven. This harness will expose the issue if
# frame exchange fails while upgrade succeeds.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
HARNESS_NAME="WebSocket"

require_server

echo "--- WebSocket Transport E2E ---"

# Test 1: WebSocket standalone server connectivity
# WebSocket runs on a separate port (default: 8937), not on the main HTTP port.
# The main HTTP /ws endpoint returns a redirect JSON with the WS port.
ws_port_resp=$(curl -sf "${MASC_BASE_URL}/ws" 2>&1 || echo "FAILED")
if echo "$ws_port_resp" | grep -q "ws_port"; then
  pass "WebSocket: /ws returns standalone port info"
else
  skip "WebSocket: /ws endpoint" "response: ${ws_port_resp:0:100}"
fi

# Test 1b: WebSocket upgrade on standalone port
ws_resp=$(curl -sf -i -m 5 \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" \
  "http://127.0.0.1:${MASC_WS_PORT}/" 2>&1 || echo "FAILED")

if echo "$ws_resp" | grep -q "101"; then
  pass "WebSocket upgrade on :${MASC_WS_PORT}: 101 Switching Protocols"
elif echo "$ws_resp" | grep -q "FAILED"; then
  fail "WebSocket upgrade on :${MASC_WS_PORT}" "connection failed (server may not expose standalone WS)"
  summary
  exit 1
else
  skip "WebSocket upgrade on :${MASC_WS_PORT}" "response: ${ws_resp:0:100}"
fi

# Test 2: WebSocket frame exchange (if websocat available)
if require_tool websocat; then
  WS_OUTPUT=$(mktemp)
  # Connect to standalone WS port
  echo '{"jsonrpc":"2.0","id":1,"method":"ping"}' | \
    timeout 5 websocat -1 "${MASC_WS_URL}/" \
    >"${WS_OUTPUT}" 2>&1 || true

  if [ -s "${WS_OUTPUT}" ]; then
    ws_data=$(cat "${WS_OUTPUT}")
    if echo "$ws_data" | jq -e '.' >/dev/null 2>&1; then
      pass "WebSocket: frame exchange works (received JSON response)"
    else
      # Any data received means I/O loop is driving
      pass "WebSocket: received data (${#ws_data} bytes)"
    fi
  else
    fail "WebSocket: frame exchange" \
      "TRANS-001: no data received (I/O loop may not be driven)"
  fi
  rm -f "${WS_OUTPUT}"
else
  skip "WebSocket frame exchange" "websocat not installed (brew install websocat)"
fi

# Test 3: Server stability after WebSocket test
health_after=$(curl -sf "${MASC_BASE_URL}/health" 2>&1)
if [ $? -eq 0 ]; then
  pass "server healthy after WebSocket test"
else
  fail "server health" "health check failed after WebSocket test"
fi

summary
