#!/usr/bin/env bash

jsonrpc_sse_data() {
  local response="$1"
  printf '%s' "$response" | sed -n 's/^data: //p'
}

jsonrpc_select_response_line() {
  local sse_data="$1"
  local id="$2"
  printf '%s\n' "$sse_data" \
    | while IFS= read -r line; do
        if printf '%s' "$line" \
          | jq -e --argjson request_id "$id" '.id? == $request_id' >/dev/null 2>&1; then
          printf '%s\n' "$line"
        fi
      done \
    | tail -n1
}

jsonrpc_normalize_response() {
  local response="$1"
  local id="$2"
  local sse_data
  sse_data="$(jsonrpc_sse_data "$response")"
  if [ -z "$sse_data" ]; then
    printf '%s' "$response"
    return 0
  fi
  local response_line
  response_line="$(jsonrpc_select_response_line "$sse_data" "$id")"
  if [ -n "$response_line" ]; then
    printf '%s' "$response_line"
  else
    printf '%s\n' "$sse_data" | tail -n1
  fi
}
