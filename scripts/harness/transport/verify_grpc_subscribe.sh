#!/usr/bin/env bash
# E2E: Verify gRPC Subscribe server streaming.
#
# Tests:
#   1. gRPC health check returns SERVING
#   2. gRPC reflection lists MascWorkspace and Health
#   3. Subscribe RPC returns subscription_started event
#   4. Subscribe stream receives broadcast events through the MCP bridge
#   5. Server stays healthy after subscriber disconnect
#
# For an externally managed server, point MASC_GRPC_SUBSCRIBER_TOKEN_FILE at
# the raw credential owned by MASC_GRPC_SUBSCRIBER_AGENT. Isolated autostart
# runs mint a short-lived worker credential and read the raw token from the
# per-agent file emitted by `masc-server login`.

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
if ! require_tool jq; then
  echo "ERROR: jq required to construct authenticated gRPC requests"
  exit 2
fi

GRPC_SUBSCRIBER_AGENT="${MASC_GRPC_SUBSCRIBER_AGENT:-grpc-e2e-harness}"
if [[ ! "$GRPC_SUBSCRIBER_AGENT" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: MASC_GRPC_SUBSCRIBER_AGENT must match [A-Za-z0-9._-]+" >&2
  exit 2
fi

read_grpc_subscriber_credential() {
  local credential_file="${MASC_GRPC_SUBSCRIBER_TOKEN_FILE:-}"
  local login_json server_exe token

  if [[ -z "$credential_file" ]]; then
    if [[ -z "$TRANSPORT_SERVER_BASE_PATH" ]]; then
      echo "MASC_GRPC_SUBSCRIBER_TOKEN_FILE is required for an externally managed server" >&2
      return 1
    fi

    if ! server_exe="$(harness_find_server_exe "$ROOT_DIR" "${SERVER_EXE:-}")"; then
      echo "failed to locate the server executable for credential minting" >&2
      return 1
    fi
    if ! login_json="$(
      env -u MCP_TOKEN -u MCP_AUTH_TOKEN -u MASC_ADMIN_TOKEN -u MASC_TOKEN \
        MASC_BASE_PATH="$TRANSPORT_SERVER_BASE_PATH" \
        MASC_BASE_PATH_INPUT="$TRANSPORT_SERVER_BASE_PATH" \
        "$server_exe" login \
        --base-path "$TRANSPORT_SERVER_BASE_PATH" \
        --host 127.0.0.1 \
        --port "$MASC_HTTP_PORT" \
        --agent "$GRPC_SUBSCRIBER_AGENT" \
        --role worker \
        --client-env MASC_GRPC_SUBSCRIBER_TOKEN \
        --json
    )"; then
      echo "failed to mint gRPC subscriber credential for ${GRPC_SUBSCRIBER_AGENT}" >&2
      return 1
    fi
    if ! credential_file="$(jq -r '.raw_token_file // empty' <<<"$login_json")"; then
      echo "login output was not valid credential JSON" >&2
      return 1
    fi
  fi

  if [[ -z "$credential_file" || ! -r "$credential_file" ]]; then
    echo "gRPC subscriber credential file is not readable: ${credential_file:-<unset>}" >&2
    return 1
  fi

  token="$(tr -d '\r\n' <"$credential_file")"
  if [[ -z "$token" ]]; then
    echo "gRPC subscriber credential file is empty: $credential_file" >&2
    return 1
  fi
  printf '%s\n' "$token"
}

if ! GRPC_AUTH_TOKEN="$(read_grpc_subscriber_credential)"; then
  fail "gRPC Subscribe auth" "unable to read the ${GRPC_SUBSCRIBER_AGENT} credential"
  summary
  exit 1
fi

# Use the same credential owner for the MCP bridge operations. This keeps the
# gRPC claimed agent, bearer owner, and MCP actor binding identical.
MASC_TRANSPORT_AUTH_TOKEN="$GRPC_AUTH_TOKEN"
export MASC_TRANSPORT_AUTH_TOKEN

subscribe_request_json() {
  local session_id="$1"
  jq -cn \
    --arg agent_name "$GRPC_SUBSCRIBER_AGENT" \
    --arg session_id "$session_id" \
    --arg auth_token "$GRPC_AUTH_TOKEN" \
    '{agent_name:$agent_name,session_id:$session_id,since_seq:"0",event_types:["message"],auth_token:$auth_token}'
}

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

subscribe_payload="$(subscribe_request_json "grpc-e2e-harness")"
subscribe_resp="$(
  grpcurl -plaintext -max-time 5 \
    -import-path "${PROTO_DIR}" \
    -proto "${MASC_GRPC_PROTO}" \
    -d @ \
    "${MASC_GRPC_ADDR}" \
    "${MASC_GRPC_SERVICE}/Subscribe" <<<"$subscribe_payload" 2>&1 || true
)"
if echo "$subscribe_resp" | grep -q "subscription_started"; then
  pass "Subscribe: received subscription_started event"
else
  fail "Subscribe" "no subscription_started event: ${subscribe_resp:0:200}"
fi

subscribe_output="$(harness_mktemp_file "masc-transport-grpc")"
listener_payload="$(subscribe_request_json "grpc-e2e-listener")"
grpcurl -plaintext \
  -import-path "${PROTO_DIR}" \
  -proto "${MASC_GRPC_PROTO}" \
  -d @ \
  "${MASC_GRPC_ADDR}" \
  "${MASC_GRPC_SERVICE}/Subscribe" >"${subscribe_output}" 2>&1 <<<"$listener_payload" &
subscribe_pid=$!
sleep 1

session_id="$(mcp_initialize_session)"
mcp_join_agent "$session_id" "$GRPC_SUBSCRIBER_AGENT" >/dev/null
mcp_broadcast "$session_id" "$GRPC_SUBSCRIBER_AGENT" "grpc-e2e-test-event" >/dev/null
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
