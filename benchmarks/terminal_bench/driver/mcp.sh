#!/usr/bin/env bash
# Minimal MCP Streamable HTTP client for the MASC server (curl + jq only).
# Source this file; requires MCP_TOKEN in env.
set -euo pipefail

MCP_URL="${MASC_MCP_URL:-http://127.0.0.1:8935/mcp}"
MCP_SESSION_ID=""
: "${MCP_TOKEN:?MCP_TOKEN required}"

_mcp_post() { # body timeout_sec -> raw response body
  local body="$1" timeout="${2:-30}"
  local -a args=(
    -sS --max-time "$timeout" -X POST "$MCP_URL"
    -H 'Content-Type: application/json'
    -H 'Accept: application/json, text/event-stream'
    -H "Authorization: Bearer ${MCP_TOKEN}"
  )
  [[ -n "${MCP_SESSION_ID}" ]] && args+=( -H "Mcp-Session-Id: ${MCP_SESSION_ID}" )
  curl "${args[@]}" --data-binary "$body"
}

_mcp_extract() { # raw -> json payload (unwrap SSE data: lines)
  local raw="$1"
  if printf '%s' "$raw" | grep -q '^data:'; then
    printf '%s' "$raw" | grep '^data:' | sed 's/^data: //' | tail -1
  else
    printf '%s' "$raw"
  fi
}

mcp_init() {
  local body resp
  body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"masc-bench","version":"0.1"}}}'
  resp="$(curl -sS -i --max-time 30 -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer ${MCP_TOKEN}" \
    --data-binary "$body")"
  MCP_SESSION_ID="$(printf '%s' "$resp" | tr -d '\r' \
    | awk 'tolower($1)=="mcp-session-id:"{print $2}' | tail -1)"
  if [[ -z "${MCP_SESSION_ID}" ]]; then
    echo "mcp_init: no mcp-session-id header" >&2; return 1
  fi
  _mcp_post '{"jsonrpc":"2.0","method":"notifications/initialized"}' 10 >/dev/null
}

mcp_call() { # id tool args_json timeout_sec -> tool result json (stdout)
  local id="$1" tool="$2" args_json="$3" timeout="${4:-60}"
  local body resp payload
  body="$(jq -cn --argjson id "$id" --arg name "$tool" --argjson a "$args_json" \
    '{jsonrpc:"2.0",id:$id,method:"tools/call",params:{name:$name,arguments:$a}}')"
  resp="$(_mcp_post "$body" "$timeout")"
  payload="$(_mcp_extract "$resp")"
  if ! printf '%s' "$payload" | jq -e '.error == null and (.result.isError // false) == false' >/dev/null 2>&1; then
    echo "mcp_call ${tool} failed: ${payload}" >&2
    return 1
  fi
  printf '%s' "$payload" | jq -c 'try (.result.content[0].text | fromjson) catch .result'
}
