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

_mcp_extract() { # raw request_id -> the response frame with that id
  # An SSE body carries progress notifications and keepalives alongside the
  # response. Taking the last data: line accepted whichever frame happened to
  # come last, and a notification satisfies a guard that only asks "no error":
  #   {"jsonrpc":"2.0","method":"notifications/progress",...}  -> passes
  # So select the frame whose id matches the request instead.
  local raw="$1" want_id="$2"
  local frames
  if printf '%s' "$raw" | grep -q '^data:'; then
    frames="$(printf '%s' "$raw" | grep '^data:' | sed 's/^data: //')"
  else
    frames="$raw"
  fi
  printf '%s' "$frames" \
    | jq -c --argjson id "$want_id" 'select(.id == $id)' 2>/dev/null \
    | tail -n 1
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
  # Guard the assignments. Callers reach mcp_call both inside a condition
  # (`if mcp_init`) and bare (`mcp_call ... >/dev/null` in bootstrap), and in
  # the bare case an unguarded `x="$(...)"` aborts the caller with curl's or
  # jq's exit code before the diagnostic below can print — the operator sees
  # an empty failure.
  resp="$(_mcp_post "$body" "$timeout")" || {
    echo "mcp_call ${tool} failed: transport error (timeout ${timeout}s)" >&2
    return 1
  }
  payload="$(_mcp_extract "$resp" "$id")" || payload=""
  if [[ -z "$payload" ]]; then
    echo "mcp_call ${tool} failed: no response frame with id ${id}: ${resp:-<empty response>}" >&2
    return 1
  fi
  # `has("result")` matters as much as the error check: a frame can be
  # well-formed, carry the right id and still be a notification rather than
  # the response.
  if ! printf '%s' "$payload" \
    | jq -e '.error == null and has("result") and (.result.isError // false) == false' >/dev/null 2>&1
  then
    echo "mcp_call ${tool} failed: ${payload}" >&2
    return 1
  fi
  # `catch .result` never worked: jq binds the error *message string* to `.`
  # inside catch, so indexing it raises "Cannot index string with string" and
  # jq exits 5 — after the guard above already called the response healthy.
  # Every tool whose content[0].text is prose rather than JSON hit that.
  printf '%s' "$payload" | jq -c '(.result.content[0].text | fromjson?) // .result'
}
