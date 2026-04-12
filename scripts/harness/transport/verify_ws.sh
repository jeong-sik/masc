#!/usr/bin/env bash
# E2E: Verify WebSocket transport.
#
# Tests:
#   1. /ws returns stable discovery JSON
#   2. Standalone WS port performs a 101 handshake
#   3. WS client receives a broadcast-delivered text frame
#   4. Server remains healthy after the WS smoke

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
HARNESS_NAME="WebSocket"

require_server

echo "--- WebSocket Transport E2E ---"

ws_discovery="$(curl -fsS "${MASC_BASE_URL}/ws" 2>&1 || true)"
read -r ws_enabled ws_port ws_url <<EOF
$(WS_DISCOVERY="$ws_discovery" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["WS_DISCOVERY"])
print(str(payload.get("enabled", False)).lower(), payload.get("ws_port", ""), payload.get("ws_url", ""))
PY
)
EOF

if [[ "$ws_enabled" = "true" && -n "$ws_port" && -n "$ws_url" ]]; then
  pass "WebSocket: /ws returns discovery JSON"
else
  fail "WebSocket: /ws discovery" "unexpected response: ${ws_discovery:0:200}"
  summary
  exit 1
fi

read_sse_external_subscriber_count() {
  curl -fsS "${MASC_BASE_URL}/metrics" 2>/dev/null \
    | awk '$1=="masc_sse_external_subscribers_total" { print int($2); found=1; exit } END { if (!found) print -1 }' \
    2>/dev/null || echo "-1"
}

ws_output="$(mktemp "${TMPDIR:-/tmp}/masc-transport-ws.XXXXXX")"
ws_handshake="$(mktemp "${TMPDIR:-/tmp}/masc-transport-ws-handshake.XXXXXX")"
ws_subscribers_before="$(read_sse_external_subscriber_count)"
MASC_WS_HOST="127.0.0.1" MASC_WS_PORT="$ws_port" WS_OUTPUT="$ws_output" \
WS_EXPECT="ws-e2e-test-event" WS_HANDSHAKE="$ws_handshake" python3 - <<'PY' &
import base64
import os
import socket
import sys

host = os.environ["MASC_WS_HOST"]
port = int(os.environ["MASC_WS_PORT"])
output_path = os.environ["WS_OUTPUT"]
expected = os.environ["WS_EXPECT"]
handshake_path = os.environ["WS_HANDSHAKE"]

sock = socket.create_connection((host, port), timeout=5)
key = base64.b64encode(os.urandom(16)).decode()
request = (
    f"GET / HTTP/1.1\r\n"
    f"Host: {host}:{port}\r\n"
    "Upgrade: websocket\r\n"
    "Connection: Upgrade\r\n"
    f"Sec-WebSocket-Key: {key}\r\n"
    "Sec-WebSocket-Version: 13\r\n\r\n"
)
sock.sendall(request.encode())

buffer = b""
while b"\r\n\r\n" not in buffer:
    chunk = sock.recv(4096)
    if not chunk:
        raise SystemExit(1)
    buffer += chunk

status_line = buffer.split(b"\r\n", 1)[0]
if b"101" not in status_line:
    raise SystemExit(2)
with open(handshake_path, "w", encoding="utf-8") as fh:
    fh.write(status_line.decode("utf-8", errors="replace"))
    fh.write("\n")
buffer = buffer.split(b"\r\n\r\n", 1)[1]
sock.settimeout(6)

def read_exact(n: int) -> bytes:
    global buffer
    data = b""
    if buffer:
        take = min(len(buffer), n)
        data += buffer[:take]
        buffer = buffer[take:]
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise EOFError("unexpected websocket EOF")
        data += chunk
    return data

for _ in range(16):
    hdr = read_exact(2)
    opcode = hdr[0] & 0x0F
    masked = (hdr[1] & 0x80) != 0
    length = hdr[1] & 0x7F
    if length == 126:
      length = int.from_bytes(read_exact(2), "big")
    elif length == 127:
      length = int.from_bytes(read_exact(8), "big")
    mask = read_exact(4) if masked else b""
    payload = read_exact(length)
    if masked:
      payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    if opcode == 0x1:
      text = payload.decode("utf-8", errors="replace")
      with open(output_path, "a", encoding="utf-8") as fh:
        fh.write(text)
        fh.write("\n")
      if expected in text:
        raise SystemExit(0)
    if opcode == 0x8:
      raise SystemExit(3)

raise SystemExit(4)
PY
ws_client_pid=$!

ws_handshake_deadline=$(( $(date +%s) + 10 ))
while [[ "$(date +%s)" -lt "$ws_handshake_deadline" ]]; do
  if [[ -s "$ws_handshake" ]]; then
    break
  fi
  if ! kill -0 "$ws_client_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

if [[ -s "$ws_handshake" ]]; then
  pass "WebSocket handshake on :${ws_port}: 101 Switching Protocols"
else
  wait "$ws_client_pid" || true
  fail "WebSocket handshake on :${ws_port}" "client did not complete upgrade"
  rm -f "$ws_output" "$ws_handshake"
  summary
  exit 1
fi

# Poll Prometheus for the SSE external-subscriber count instead of a
# fixed sleep. The Python client above needs time for:
#   1. socket connect
#   2. upgrade request/response (101 Switching Protocols)
#   3. server-side [create_websocket] callback to run and call
#      [Sse.subscribe_external] registering this session as an
#      external broadcast recipient
# Step 3 happens asynchronously inside the httpun-ws [Wsd.t] setup and
# is NOT guaranteed to complete before [respond_with_upgrade] returns.
# The previous fixed [sleep 1] raced this registration: on a loaded CI
# runner, the subscription could be placed AFTER the mcp_broadcast
# call, so the broadcast event had no subscriber to deliver to and the
# Python client's 6-second recv timeout elapsed with zero frames.
#
# Polling against [masc_sse_external_subscribers_total] provides the
# deterministic barrier we actually need. The previous
# [websocket.session_count] guard was still racy because
# [server_mcp_transport_ws.ml] inserts the session before it calls
# [Sse.subscribe_external], so /health could report the new WS session
# even while the SSE fanout registry was still missing the subscriber.
#
# Falls back to the old 1-second wait if /metrics is unavailable.
ws_target_subscribers=1
if [[ "$ws_subscribers_before" =~ ^[0-9]+$ ]]; then
  ws_target_subscribers=$(( ws_subscribers_before + 1 ))
fi

ws_ready_deadline=$(( $(date +%s) + 10 ))
while [[ "$(date +%s)" -lt "$ws_ready_deadline" ]]; do
  ws_subscribers="$(read_sse_external_subscriber_count)"
  if [[ "$ws_subscribers" =~ ^[0-9]+$ ]] && [[ "$ws_subscribers" -ge "$ws_target_subscribers" ]]; then
    break
  fi
  sleep 0.2
done

session_id="$(mcp_initialize_session)"
mcp_join_agent "$session_id" "transport-harness" >/dev/null
mcp_broadcast "$session_id" "transport-harness" "ws-e2e-test-event" >/dev/null

if wait "$ws_client_pid"; then
  if grep -q "ws-e2e-test-event" "$ws_output"; then
    pass "WebSocket: received broadcast-delivered text frame"
  else
    fail "WebSocket frame delivery" "frame received but expected broadcast text missing"
  fi
else
  fail "WebSocket frame delivery" "client did not receive a text frame"
fi
rm -f "$ws_output" "$ws_handshake"

if curl -fsS "${MASC_BASE_URL}/health" >/dev/null 2>&1; then
  pass "server healthy after WebSocket test"
else
  fail "server health" "health check failed after WebSocket test"
fi

summary
