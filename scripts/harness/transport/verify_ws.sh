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

ws_discovery="$(curl -fsS "${MASC_HTTP_BASE_URL}/ws" 2>&1 || true)"
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

ws_output="$(mktemp "${TMPDIR:-/tmp}/masc-transport-ws.XXXXXX")"
ws_handshake="$(mktemp "${TMPDIR:-/tmp}/masc-transport-ws-handshake.XXXXXX")"
ws_auth_token="$(transport_auth_token)"
MASC_WS_HOST="127.0.0.1" MASC_WS_PORT="$ws_port" WS_OUTPUT="$ws_output" \
WS_EXPECT="ws-e2e-test-event" WS_HANDSHAKE="$ws_handshake" \
WS_AUTH_TOKEN="$ws_auth_token" python3 - <<'PY' &
import base64
import json
import os
import socket
import sys

host = os.environ["MASC_WS_HOST"]
port = int(os.environ["MASC_WS_PORT"])
output_path = os.environ["WS_OUTPUT"]
expected = os.environ["WS_EXPECT"]
handshake_path = os.environ["WS_HANDSHAKE"]
auth_token = os.environ.get("WS_AUTH_TOKEN", "")

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

def send_text(text: str) -> None:
    payload = text.encode("utf-8")
    mask = os.urandom(4)
    length = len(payload)
    if length < 126:
        header = bytes([0x81, 0x80 | length])
    elif length <= 0xFFFF:
        header = bytes([0x81, 0x80 | 126]) + length.to_bytes(2, "big")
    else:
        header = bytes([0x81, 0x80 | 127]) + length.to_bytes(8, "big")
    masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    sock.sendall(header + mask + masked)

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

def read_text_frame() -> tuple[int, str]:
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
      return opcode, payload.decode("utf-8", errors="replace")
    if opcode == 0x8:
      return opcode, ""
    return opcode, ""

hello_params = {
    "protocol": "dashboard-ws.v1",
    "features": ["snapshot", "delta", "mode_snapshot"],
}
if auth_token:
    hello_params["token"] = auth_token
send_text(json.dumps({
    "jsonrpc": "2.0",
    "id": 1,
    "method": "dashboard/hello",
    "params": hello_params,
}, separators=(",", ":")))

for _ in range(8):
    opcode, text = read_text_frame()
    if opcode == 0x8:
      raise SystemExit(3)
    if not text:
      continue
    try:
      payload = json.loads(text)
    except json.JSONDecodeError:
      continue
    if payload.get("id") == 1:
      if "result" in payload:
        break
      raise SystemExit(5)
else:
    raise SystemExit(6)

for _ in range(16):
    opcode, text = read_text_frame()
    if opcode == 0x1:
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

session_id="$(mcp_initialize_session)"
mcp_join_agent "$session_id" "transport-harness" >/dev/null

# The server-side WS callback registers the session as an external broadcast
# recipient asynchronously after the 101 handshake. Use a bounded broadcast
# retry loop as the readiness barrier.
ws_broadcast_deadline=$(( $(date +%s) + 10 ))
while [[ "$(date +%s)" -lt "$ws_broadcast_deadline" ]]; do
  if ! kill -0 "$ws_client_pid" >/dev/null 2>&1; then
    break
  fi
  mcp_broadcast "$session_id" "transport-harness" "ws-e2e-test-event" >/dev/null || true
  sleep 0.5
done

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

if curl -fsS "${MASC_HTTP_BASE_URL}/health" >/dev/null 2>&1; then
  pass "server healthy after WebSocket test"
else
  fail "server health" "health check failed after WebSocket test"
fi

summary
