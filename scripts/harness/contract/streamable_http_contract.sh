#!/usr/bin/env bash
set -euo pipefail

MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
BASE_URL="${MCP_URL%/mcp}"

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

post_with_accept() {
  local accept_header="$1"
  local body="$2"
  local header_file="$3"
  local body_file="$4"

  curl -sS -D "$header_file" -o "$body_file" \
    -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H "Accept: $accept_header" \
    -d "$body"
}

status_code() {
  local header_file="$1"
  awk 'toupper($1) ~ /^HTTP\/[0-9.]+$/ { code=$2 } END { print code }' "$header_file"
}

require_header_contains() {
  local header_file="$1"
  local key="$2"
  local needle="$3"
  if ! awk -v k="$key" -v n="$needle" '
    BEGIN { found=0 }
    tolower($0) ~ "^" tolower(k) ":" {
      if (index(tolower($0), tolower(n)) > 0) found=1
    }
    END { exit(found ? 0 : 1) }
  ' "$header_file"; then
    echo "FAIL: missing header '$key' containing '$needle'"
    cat "$header_file"
    exit 1
  fi
}

echo "[1/4] strict Accept rejection"
h1="$tmpdir/reject.headers"
b1="$tmpdir/reject.body"
post_with_accept "application/json" \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"contract","version":"1.0"},"capabilities":{}}}' \
  "$h1" "$b1"
code1="$(status_code "$h1")"
if [ "$code1" != "400" ]; then
  echo "FAIL: expected 400 for non-streamable Accept, got $code1"
  cat "$h1"
  cat "$b1"
  exit 1
fi
if ! grep -qi "Invalid Accept header" "$b1"; then
  echo "FAIL: expected invalid accept error body"
  cat "$b1"
  exit 1
fi

echo "[2/4] streamable Accept success"
h2="$tmpdir/ok.headers"
b2="$tmpdir/ok.body"
post_with_accept "application/json, text/event-stream" \
  '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"contract","version":"1.0"},"capabilities":{}}}' \
  "$h2" "$b2"
code2="$(status_code "$h2")"
if [ "$code2" != "200" ]; then
  echo "FAIL: expected 200 for streamable Accept, got $code2"
  cat "$h2"
  cat "$b2"
  exit 1
fi

echo "[3/4] /sse deprecation headers"
h3="$tmpdir/sse.headers"
curl -sS -D "$h3" -o /dev/null --max-time 1 \
  -H 'Accept: text/event-stream' \
  "$BASE_URL/sse" || true
require_header_contains "$h3" "Deprecation" "true"
require_header_contains "$h3" "Link" "</mcp>; rel=\"successor-version\""

echo "[4/4] /messages deprecation headers"
h4="$tmpdir/messages.headers"
b4="$tmpdir/messages.body"
curl -sS -D "$h4" -o "$b4" \
  -X POST "$BASE_URL/messages" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"ping"}'
code4="$(status_code "$h4")"
if [ "$code4" != "400" ]; then
  echo "FAIL: expected 400 for missing session_id on /messages, got $code4"
  cat "$h4"
  cat "$b4"
  exit 1
fi
require_header_contains "$h4" "Deprecation" "true"

echo "PASS: streamable_http contract harness"
