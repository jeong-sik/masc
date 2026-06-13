#!/usr/bin/env bash
# E2E: Verify gRPC Subscribe server streaming.
#
# Tests:
#   1. gRPC health check returns SERVING
#   2. gRPC reflection lists MascWorkspace and Health
#   3. Subscribe RPC returns subscription_started event
#   4. Subscribe stream receives broadcast events through the MCP bridge
#   5. Server stays healthy after subscriber disconnect

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/harness/transport/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck disable=SC2034
HARNESS_NAME="gRPC-Subscribe"

require_server

PROTO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)/proto"
MASC_GRPC_SERVICE="masc.workspace.v1.MascWorkspace"
MASC_GRPC_PROTO="masc_workspace.proto"

if ! require_tool grpcurl; then
  echo "ERROR: grpcurl required for gRPC E2E tests"
  exit 2
fi

echo "--- gRPC Subscribe E2E ---"

wait_for_grpc_health() {
  local deadline=$((SECONDS + 20))
  local response=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    response="$(
      grpcurl -plaintext \
        -import-path "${PROTO_DIR}" \
        -proto grpc_health_v1.proto \
        -d "{\"service\":\"${MASC_GRPC_SERVICE}\"}" \
        "${MASC_GRPC_ADDR}" \
        grpc.health.v1.Health/Check 2>&1 || true
    )"
    if echo "$response" | grep -q "SERVING"; then
      printf '%s\n' "$response"
      return 0
    fi
    sleep 1
  done
  printf '%s\n' "$response"
  return 1
}

health_resp="$(wait_for_grpc_health || true)"
if echo "$health_resp" | grep -q "SERVING"; then
  pass "gRPC health: SERVING"
elif echo "$health_resp" | grep -qi "connect"; then
  fail "gRPC health" "connection refused (gRPC server not running on ${MASC_GRPC_ADDR})"
  summary
  exit 1
else
  fail "gRPC health" "${health_resp:0:160}"
fi

services="$(grpcurl -plaintext "${MASC_GRPC_ADDR}" list 2>&1 || true)"
if echo "$services" | grep -q "${MASC_GRPC_SERVICE}"; then
  pass "gRPC reflection: MascWorkspace listed"
else
  fail "gRPC reflection" "MascWorkspace missing from reflection output"
fi
if echo "$services" | grep -q "grpc.health.v1.Health"; then
  pass "gRPC reflection: Health listed"
else
  fail "gRPC reflection" "grpc.health.v1.Health missing from reflection output"
fi

subscribe_resp="$(
  grpcurl -plaintext -max-time 5 \
    -import-path "${PROTO_DIR}" \
    -proto "${MASC_GRPC_PROTO}" \
    -d '{"agent_name":"e2e-harness","session_id":"grpc-e2e-harness","since_seq":"0","event_types":["message"]}' \
    "${MASC_GRPC_ADDR}" \
    "${MASC_GRPC_SERVICE}/Subscribe" 2>&1 || true
)"
if echo "$subscribe_resp" | grep -q "subscription_started"; then
  pass "Subscribe: received subscription_started event"
else
  fail "Subscribe" "no subscription_started event: ${subscribe_resp:0:200}"
fi

subscribe_output="$(harness_mktemp_file "masc-transport-grpc")"
grpcurl -plaintext \
  -import-path "${PROTO_DIR}" \
  -proto "${MASC_GRPC_PROTO}" \
  -d '{"agent_name":"e2e-grpc-listener","session_id":"grpc-e2e-listener","since_seq":"0","event_types":["message"]}' \
  "${MASC_GRPC_ADDR}" \
  "${MASC_GRPC_SERVICE}/Subscribe" >"${subscribe_output}" 2>&1 &
subscribe_pid=$!
sleep 1

session_id="$(mcp_initialize_session)"
mcp_join_agent "$session_id" "transport-harness" >/dev/null
mcp_broadcast "$session_id" "transport-harness" "grpc-e2e-test-event" >/dev/null
sleep 2

kill "$subscribe_pid" >/dev/null 2>&1 || true
wait "$subscribe_pid" >/dev/null 2>&1 || true

if grep -q "grpc-e2e-test-event\|sse_broadcast" "${subscribe_output}"; then
  pass "Subscribe: received broadcast event via MCP bridge"
else
  fail "Subscribe: broadcast bridge" "no broadcast observed in stream output"
fi
rm -f "${subscribe_output}"

if curl -fsS "${MASC_HTTP_BASE_URL}/health" >/dev/null 2>&1; then
  pass "server healthy after subscriber disconnect"
else
  fail "server health after disconnect" "health check failed"
fi

summary
