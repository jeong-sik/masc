#!/usr/bin/env bash
# E2E: Compare transport read-model truth with actual reachability probes.
#
# The transport dashboard can drift from the real listener state. This harness
# keeps `/health`, `/api/v1/dashboard/transport-health`, `masc_transport_status`,
# and live probes in one report so task-050 style fixes have a regression target.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/harness/transport/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck disable=SC2034
HARNESS_NAME="Transport-Truth"

require_server

for tool in curl jq python3; do
  if ! require_tool "$tool"; then
    echo "ERROR: ${tool} required for transport truth harness" >&2
    exit 2
  fi
done

echo "--- Transport Truth Harness ---"

json_bool() {
  local json="$1"
  local filter="$2"
  jq -r "${filter} // \"missing\"" <<<"$json" 2>/dev/null || printf 'missing\n'
}

fetch_transport_health_json() {
  local body=""
  for _ in {1..25}; do
    if body="$(curl -fsS --max-time 5 \
      "${MASC_BASE_URL}/api/v1/dashboard/transport-health" 2>/dev/null)" &&
      jq -e '.streamable_http and .grpc and .websocket and .http2' \
        <<<"$body" >/dev/null 2>&1; then
      printf '%s\n' "$body"
      return 0
    fi
    sleep 1
  done
  if [[ -n "$body" ]]; then
    printf '%s\n' "$body"
  else
    printf '{}\n'
  fi
  return 1
}

mcp_response_text() {
  local payload
  payload="$(cat)"
  MCP_RESPONSE_PAYLOAD="$payload" python3 - <<'PY'
import json
import os
import sys

payload = os.environ.get("MCP_RESPONSE_PAYLOAD", "")
candidates = []
for raw in payload.splitlines():
    line = raw.strip()
    if line.startswith("data:"):
        line = line[len("data:"):].strip()
    elif not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue
    result = obj.get("result") or {}
    envelopes = [result]
    if isinstance(result.get("resultEnvelope"), dict):
        envelopes.append(result["resultEnvelope"])
    for envelope in envelopes:
        for item in envelope.get("content") or []:
            if item.get("type") == "text":
                candidates.append(item.get("text", ""))

if not candidates:
    sys.exit(1)
print(candidates[-1])
PY
}

mcp_error_message() {
  local payload
  payload="$(cat)"
  MCP_RESPONSE_PAYLOAD="$payload" python3 - <<'PY'
import json
import os
import sys

payload = os.environ.get("MCP_RESPONSE_PAYLOAD", "")
for raw in payload.splitlines():
    line = raw.strip()
    if line.startswith("data:"):
        line = line[len("data:"):].strip()
    elif not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue
    error = obj.get("error")
    if isinstance(error, dict):
        print(error.get("message", "unknown MCP error"))
        sys.exit(0)
sys.exit(1)
PY
}

probe_tcp() {
  local host="$1"
  local port="$2"
  python3 - "$host" "$port" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
try:
    with socket.create_connection((host, port), timeout=2):
        pass
except OSError:
    sys.exit(1)
PY
}

probe_ws_handshake() {
  local host="$1"
  local port="$2"
  python3 - "$host" "$port" <<'PY'
import base64
import os
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
try:
    sock = socket.create_connection((host, port), timeout=3)
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    request = (
        f"GET / HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(request.encode("ascii"))
    response = b""
    sock.settimeout(3)
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(4096)
        if not chunk:
            break
        response += chunk
finally:
    try:
        sock.close()
    except Exception:
        pass

status = response.split(b"\r\n", 1)[0]
if b"101" not in status:
    sys.exit(1)
PY
}

probe_sse() {
  local headers
  headers="$(mktemp "${TMPDIR:-/tmp}/masc-transport-truth-sse.XXXXXX")"
  curl -sS -N --max-time 2 -D "$headers" -o /dev/null \
    -H "Accept: application/json, text/event-stream" \
    "${MASC_BASE_URL}/mcp?sse_kind=observer&session_id=transport-truth-$$" \
    >/dev/null 2>&1 || true
  if grep -qi "content-type:.*text/event-stream" "$headers"; then
    rm -f "$headers"
    return 0
  fi
  rm -f "$headers"
  return 1
}

probe_h2c() {
  if ! curl --version | grep -q "HTTP2"; then
    return 2
  fi
  curl --http2-prior-knowledge -fsS --max-time 3 -X POST \
    "${MASC_BASE_URL}/mcp" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"transport-truth-h2","version":"1.0"}}}' \
    >/dev/null
}

compare_truth() {
  local name="$1"
  local dashboard="$2"
  local tool="$3"
  local actual="$4"
  local detail="$5"
  local mismatches=()

  if [[ "$actual" = "skip" ]]; then
    skip "${name} truth" "$detail"
    return
  fi
  if [[ "$dashboard" != "missing" && "$dashboard" != "$actual" ]]; then
    mismatches+=("dashboard=${dashboard}")
  fi
  if [[ "$tool" != "missing" && "$tool" != "$actual" ]]; then
    mismatches+=("tool=${tool}")
  fi
  if [[ "${#mismatches[@]}" -gt 0 ]]; then
    fail "${name} truth mismatch" "${mismatches[*]} actual=${actual} ${detail}"
  else
    pass "${name} truth agrees (${detail})"
  fi
}

health_json="$(curl -fsS --max-time 5 "${MASC_BASE_URL}/health")"
if jq -e '.version and .paths and .startup' <<<"$health_json" >/dev/null; then
  pass "/health returns structured server health"
else
  fail "/health structure" "missing version, paths, or startup"
fi

if transport_health_json="$(fetch_transport_health_json)"; then
  pass "dashboard transport-health contains transport sections"
else
  fail "dashboard transport-health" "missing one of streamable_http/grpc/websocket/http2"
fi

transport_status_json='{}'
if session_id="$(mcp_initialize_session 2>/dev/null)"; then
  transport_status_response="$(mcp_call_tool "$session_id" "masc_transport_status" '{}' 21 2>/dev/null || true)"
  transport_status_text="$(printf '%s' "$transport_status_response" | mcp_response_text || true)"
  if jq -e '.http and .grpc and .websocket and .enabled_protocols' \
    <<<"$transport_status_text" >/dev/null 2>&1; then
    transport_status_json="$transport_status_text"
    pass "masc_transport_status returns transport read model"
  elif tool_error="$(printf '%s' "$transport_status_response" | mcp_error_message)"; then
    skip "masc_transport_status" "$tool_error"
  else
    fail "masc_transport_status" "could not decode JSON tool content"
  fi
else
  fail "masc_transport_status" "MCP initialize failed"
fi

if mcp_initialize_session >/dev/null; then
  actual_http="true"
else
  actual_http="false"
fi
dashboard_http="$(json_bool "$transport_health_json" '.streamable_http.supports_post')"
tool_http="$(json_bool "$transport_status_json" '.streamable_http_default // .http.enabled')"
compare_truth "streamable-http" "$dashboard_http" "$tool_http" "$actual_http" \
  "path=/mcp"

if probe_sse; then
  actual_sse="true"
else
  actual_sse="false"
fi
dashboard_sse="$(json_bool "$transport_health_json" '.streamable_http.supports_sse_upgrade')"
tool_sse="$(jq -r 'if (.http.sse_url // "") != "" then "true" else "missing" end' \
  <<<"$transport_status_json" 2>/dev/null || printf 'missing\n')"
compare_truth "observer-sse" "$dashboard_sse" "$tool_sse" "$actual_sse" \
  "path=/mcp?sse_kind=observer"

grpc_port="$(json_bool "$transport_health_json" '.grpc.port')"
if [[ "$grpc_port" =~ ^[0-9]+$ ]] && probe_tcp "127.0.0.1" "$grpc_port"; then
  actual_grpc="true"
else
  actual_grpc="false"
fi
dashboard_grpc="$(json_bool "$transport_health_json" '.grpc.listening')"
tool_grpc="$(json_bool "$transport_status_json" '.grpc.listening')"
compare_truth "grpc" "$dashboard_grpc" "$tool_grpc" "$actual_grpc" \
  "tcp=127.0.0.1:${grpc_port}"

ws_discovery="$(curl -fsS --max-time 5 "${MASC_BASE_URL}/ws" 2>/dev/null || printf '{}')"
ws_port="$(jq -r '.ws_port // empty' <<<"$ws_discovery" 2>/dev/null || true)"
if [[ "$ws_port" =~ ^[0-9]+$ ]] && probe_ws_handshake "127.0.0.1" "$ws_port"; then
  actual_ws="true"
else
  actual_ws="false"
fi
dashboard_ws="$(json_bool "$transport_health_json" '.websocket.listening')"
tool_ws="$(json_bool "$transport_status_json" '.websocket.listening')"
compare_truth "websocket" "$dashboard_ws" "$tool_ws" "$actual_ws" \
  "port=${ws_port:-missing}"

dashboard_h2="$(json_bool "$transport_health_json" '.http2.multiplex_ready')"
tool_h2="$(
  jq -r '
    if has("http2") then
      (.http2.multiplex_ready // "missing")
    elif ((.enabled_protocols // []) | index("h2c") != null) then
      "true"
    else
      "missing"
    end
  ' \
    <<<"$transport_status_json" 2>/dev/null || printf 'missing\n'
)"
if [[ "$dashboard_h2" = "true" || "$tool_h2" = "true" ]]; then
  if probe_h2c; then
    actual_h2="true"
  else
    case "$?" in
      2) actual_h2="skip" ;;
      *) actual_h2="false" ;;
    esac
  fi
else
  actual_h2="skip"
fi
compare_truth "http2-h2c" "$dashboard_h2" "$tool_h2" "$actual_h2" \
  "listener_mode=$(json_bool "$transport_health_json" '.http2.listener_mode')"

summary
