#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

[[ -x quickstart.sh ]] || { echo "quickstart-smoke: quickstart.sh is not executable" >&2; exit 1; }
[[ -x _build/default/bin/main_eio.exe ]] || {
  echo "quickstart-smoke: build _build/default/bin/main_eio.exe first" >&2
  exit 1
}

tmp="$(mktemp -d -t masc-quickstart-smoke.XXXXXX)"
base_path="$tmp/base"
quickstart_log="$tmp/quickstart.log"
unauth_body="$tmp/unauth.body"
initialize_body="$tmp/initialize.body"
initialize_payload="$tmp/initialize.json"
server_pid=""

capture_server_pid() {
  server_pid="$(
    sed -n 's/.*server starting (pid \([0-9][0-9]*\),.*/\1/p' "$quickstart_log" \
      | tail -n 1
  )"
}

cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$server_pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -9 "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

pick_free_port() {
  python3 <<'PY'
import socket

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

port="${MASC_QUICKSTART_SMOKE_PORT:-$(pick_free_port)}"
if ! env -u OLLAMA_CLOUD_API_KEY \
  MASC_SKIP_DASHBOARD_BUILD=1 \
  MASC_GRPC_ENABLED=0 \
  MASC_WS_ENABLED=0 \
  MASC_RUNTIME_EVENTS=0 \
  MASC_QUICKSTART_HEALTH_TIMEOUT=60 \
  ./quickstart.sh \
    --base-path "$base_path" \
    --port "$port" \
    --no-open >"$quickstart_log" 2>&1
then
  capture_server_pid
  cat "$quickstart_log" >&2
  exit 1
fi
capture_server_pid

[[ "$server_pid" =~ ^[0-9]+$ ]] || {
  echo "quickstart-smoke: could not recover the server PID" >&2
  cat "$quickstart_log" >&2
  exit 1
}
kill -0 "$server_pid" 2>/dev/null || {
  echo "quickstart-smoke: quickstart server is not running" >&2
  cat "$quickstart_log" >&2
  exit 1
}

env_file="$base_path/.masc/config/mcp-client.env"
raw_token_file="$base_path/.masc/auth/quickstart-mcp-client.token"
[[ -f "$env_file" ]] || { echo "quickstart-smoke: missing $env_file" >&2; exit 1; }
[[ "$(file_mode "$env_file")" == "600" ]] || {
  echo "quickstart-smoke: mcp-client.env is not mode 600" >&2
  exit 1
}
[[ -f "$raw_token_file" ]] || {
  echo "quickstart-smoke: missing raw token file" >&2
  exit 1
}
[[ "$(file_mode "$raw_token_file")" == "600" ]] || {
  echo "quickstart-smoke: raw token file is not mode 600" >&2
  exit 1
}

# shellcheck source=/dev/null
source "$env_file"
[[ "${MASC_OPERATOR_AGENT:-}" == "quickstart-mcp-client" ]] || {
  echo "quickstart-smoke: wrong MASC_OPERATOR_AGENT" >&2
  exit 1
}
[[ -n "${MASC_TOKEN:-}" ]] || { echo "quickstart-smoke: MASC_TOKEN is empty" >&2; exit 1; }
[[ "${MASC_OPERATOR_TOKEN:-}" == "$MASC_TOKEN" ]] || {
  echo "quickstart-smoke: operator and MCP bearer exports diverge" >&2
  exit 1
}
[[ "$(<"$raw_token_file")" == "$MASC_TOKEN" ]] || {
  echo "quickstart-smoke: persisted and exported bearers diverge" >&2
  exit 1
}

if find "$base_path/.masc/config/keepers" -type f -name '*.toml' -print -quit \
  2>/dev/null | grep -q .
then
  echo "quickstart-smoke: default quickstart unexpectedly seeded a Keeper" >&2
  exit 1
fi

# quickstart.sh waits on /health, which answers as soon as the process serves
# HTTP. That is liveness, not readiness: the auth config is loaded later, and
# until it is, /mcp raises Auth_config_error and answers 503 rather than the
# 401 asserted below. /dashboard answering 200 does not close that window
# either -- it is a third surface with its own timing.
#
# /health/ready is the surface that states readiness, and it reports the phase
# it is still in. Waiting on it is not a retry around a flaky assertion: the
# assertions below still run exactly once, against a server that has said it is
# ready. A server that never becomes ready fails here, naming the phase it
# stalled in, instead of failing later as a confusing wrong status code.
ready_deadline=$((SECONDS + 60))
ready_body="$tmp/readiness.json"
while :; do
  ready_code="$(curl -sS -o "$ready_body" -w '%{http_code}' \
    "http://127.0.0.1:${port}/health/ready" || echo "000")"
  [[ "$ready_code" == "200" ]] && break
  if (( SECONDS >= ready_deadline )); then
    echo "quickstart-smoke: server not ready after 60s (HTTP $ready_code): $(cat "$ready_body")" >&2
    exit 1
  fi
  sleep 1
done

dashboard_code="$(curl -sS -o /dev/null -w '%{http_code}' \
  "http://127.0.0.1:${port}/dashboard")"
[[ "$dashboard_code" == "200" ]] || {
  echo "quickstart-smoke: dashboard returned HTTP $dashboard_code" >&2
  exit 1
}

printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"quickstart-smoke","version":"1.0"}}}' \
  >"$initialize_payload"

unauth_code="$(curl -sS -o "$unauth_body" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data-binary "@$initialize_payload" \
  "http://127.0.0.1:${port}/mcp")"
[[ "$unauth_code" == "401" ]] || {
  echo "quickstart-smoke: unauthenticated MCP returned HTTP $unauth_code, expected 401" >&2
  exit 1
}

auth_code="$(curl -sS -o "$initialize_body" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "Authorization: Bearer ${MASC_TOKEN}" \
  --data-binary "@$initialize_payload" \
  "http://127.0.0.1:${port}/mcp")"
[[ "$auth_code" == "200" ]] || {
  echo "quickstart-smoke: authenticated MCP returned HTTP $auth_code" >&2
  exit 1
}

python3 - "$initialize_body" <<'PY'
import json
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
payload = text
if not text.lstrip().startswith("{"):
    payload = next(
        (line[6:] for line in text.splitlines() if line.startswith("data: ")),
        "",
    )
if not payload:
    raise SystemExit("quickstart-smoke: initialize returned no JSON payload")
name = json.loads(payload).get("result", {}).get("serverInfo", {}).get("name")
if name != "masc":
    raise SystemExit(f"quickstart-smoke: unexpected serverInfo.name={name!r}")
PY

printf 'quickstart-smoke: dashboard=200 unauthenticated_mcp=401 authenticated_mcp=200 env_mode=600 server=masc\n'
