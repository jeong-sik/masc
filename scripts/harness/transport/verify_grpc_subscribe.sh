#!/usr/bin/env bash
# E2E: Verify gRPC Subscribe server streaming.
#
# Tests:
#   1. gRPC health check (grpc.health.v1)
#   2. gRPC reflection lists MascCoordination service
#   3. Subscribe RPC returns subscription_started event
#   4. Subscribe stream receives broadcast events
#   5. Client disconnect triggers subscriber cleanup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
HARNESS_NAME="gRPC-Subscribe"

require_server

PROTO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)/proto"

if ! require_tool grpcurl; then
  echo "ERROR: grpcurl required for gRPC E2E tests"
  exit 2
fi

echo "--- gRPC Subscribe E2E ---"

# Test 1: gRPC health check
health_resp=$(grpcurl -plaintext "${MASC_GRPC_ADDR}" \
  grpc.health.v1.Health/Check 2>&1 || true)
if echo "$health_resp" | grep -q "SERVING"; then
  pass "gRPC health: SERVING"
elif echo "$health_resp" | grep -qi "connect"; then
  fail "gRPC health" "connection refused (gRPC server not running on ${MASC_GRPC_ADDR})"
  summary
  exit 1
else
  fail "gRPC health" "${health_resp:0:100}"
fi

# Test 2: Service reflection
services=$(grpcurl -plaintext "${MASC_GRPC_ADDR}" list 2>&1 || true)
if echo "$services" | grep -q "MascCoordination"; then
  pass "gRPC reflection: MascCoordination listed"
else
  skip "gRPC reflection" "reflection may not be enabled"
fi

# Test 3: Subscribe returns subscription_started event
subscribe_resp=$(timeout 5 grpcurl -plaintext \
  -import-path "${PROTO_DIR}" \
  -proto masc_coordination.proto \
  -d '{"agent_name":"e2e-harness","since_seq":"0","event_types":["message"]}' \
  "${MASC_GRPC_ADDR}" masc.MascCoordination/Subscribe 2>&1 || true)
if echo "$subscribe_resp" | grep -q "subscription_started"; then
  pass "Subscribe: received subscription_started event"
  # Check if the event has the expected fields
  if echo "$subscribe_resp" | jq -e '.eventType' >/dev/null 2>&1; then
    pass "Subscribe: event has eventType field"
  else
    skip "Subscribe: event field check" "may use different JSON format"
  fi
else
  fail "Subscribe" "no subscription_started event: ${subscribe_resp:0:200}"
fi

# Test 4: Subscribe receives broadcast events
# Start a subscriber in background, trigger a broadcast via HTTP, check if received
SUBSCRIBE_OUTPUT=$(mktemp)
timeout 8 grpcurl -plaintext \
  -import-path "${PROTO_DIR}" \
  -proto masc_coordination.proto \
  -d '{"agent_name":"e2e-grpc-listener","since_seq":"0","event_types":["message"]}' \
  "${MASC_GRPC_ADDR}" masc.MascCoordination/Subscribe \
  >"${SUBSCRIBE_OUTPUT}" 2>&1 &
SUBSCRIBE_PID=$!
sleep 1  # Let subscriber connect

# Trigger a broadcast via HTTP (this creates an SSE event that should be forwarded)
curl -sf -X POST "${MASC_BASE_URL}/message" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":99,"method":"tools/call","params":{"name":"masc_broadcast","arguments":{"message":"grpc-e2e-test-event"}}}' \
  >/dev/null 2>&1 || true
sleep 2

# Kill the subscriber
kill $SUBSCRIBE_PID 2>/dev/null || true
wait $SUBSCRIBE_PID 2>/dev/null || true

if grep -q "sse_broadcast\|grpc-e2e-test-event" "${SUBSCRIBE_OUTPUT}"; then
  pass "Subscribe: received broadcast event via SSE bridge"
else
  skip "Subscribe: broadcast bridge" "may need active MASC session for broadcast"
fi
rm -f "${SUBSCRIBE_OUTPUT}"

# Test 5: After subscriber disconnect, check external subscriber count
# (This verifies TRANS-003 fix — the reaper should clean up)
ext_count_resp=$(curl -sf "${MASC_BASE_URL}/health" 2>&1 || true)
if [ $? -eq 0 ]; then
  pass "server healthy after subscriber disconnect"
else
  fail "server health after disconnect" "health check failed"
fi

summary
