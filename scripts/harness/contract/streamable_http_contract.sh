#!/usr/bin/env bash
set -euo pipefail

MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
BASE_URL="${MCP_URL%/mcp}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/harness/lib/mcp_jsonrpc.sh
source "${SCRIPT_DIR}/../lib/mcp_jsonrpc.sh"

tmpdir="$(mktemp -d)"
AUTH_HEADER_FILE=""
AUTH_TOKEN="$(mcp_default_auth_token)"
if [ -n "$AUTH_TOKEN" ]; then
  AUTH_HEADER_FILE="$tmpdir/auth.header"
  printf 'Authorization: Bearer %s\n' "$AUTH_TOKEN" > "$AUTH_HEADER_FILE"
fi
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

curl_with_retry() {
  local attempt=1
  local max_attempts="${CURL_RETRY_COUNT:-1}"
  local retry_delay="${CURL_RETRY_DELAY_SEC:-1}"
  local timeout_sec="${CURL_TIMEOUT_SEC:-25}"

  while true; do
    if curl --max-time "$timeout_sec" "$@"; then
      return 0
    fi
    local status=$?
    if [ "$attempt" -ge "$max_attempts" ]; then
      return "$status"
    fi
    case "$status" in
      7|28)
        sleep "$retry_delay"
        attempt=$((attempt + 1))
        ;;
      *)
        return "$status"
        ;;
    esac
  done
}

wait_for_mcp_ready() {
  local timeout_sec="${MCP_READY_TIMEOUT_SEC:-20}"
  local deadline=$(( $(date +%s) + timeout_sec ))
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    if curl -fsS --max-time 2 "$BASE_URL/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "FAIL: MCP server did not become ready at $BASE_URL" >&2
  return 1
}

post_with_accept_auth() {
  local accept_header="$1"
  local body="$2"
  local header_file="$3"
  local body_file="$4"
  local auth_header="${5:-__DEFAULT_AUTH__}"
  local -a extra_headers=(
    -H 'Content-Type: application/json'
    -H "Accept: $accept_header"
  )
  if [ "$auth_header" = "__DEFAULT_AUTH__" ] && [ -n "$AUTH_HEADER_FILE" ]; then
    extra_headers+=( -H "@$AUTH_HEADER_FILE" )
  elif [ "$auth_header" != "__NO_AUTH__" ] && [ -n "$auth_header" ]; then
    extra_headers+=( -H "Authorization: $auth_header" )
  fi

  curl_with_retry -sS -D "$header_file" -o "$body_file" \
    -X POST "$MCP_URL" \
    "${extra_headers[@]}" \
    -d "$body"
}

post_with_accept() {
  post_with_accept_auth "$1" "$2" "$3" "$4"
}

post_with_session() {
  local session_id="$1"
  local protocol_version="$2"
  local body="$3"
  local header_file="$4"
  local body_file="$5"

  local -a extra_headers=(
    -H 'Content-Type: application/json'
    -H 'Accept: application/json, text/event-stream'
    -H "Mcp-Session-Id: $session_id"
  )
  if [ -n "$protocol_version" ]; then
    extra_headers+=(-H "Mcp-Protocol-Version: $protocol_version")
  fi
  if [ -n "$AUTH_HEADER_FILE" ]; then
    extra_headers+=( -H "@$AUTH_HEADER_FILE" )
  fi

  curl_with_retry -sS -D "$header_file" -o "$body_file" \
    -X POST "$MCP_URL" \
    "${extra_headers[@]}" \
    -d "$body"
}

get_with_session() {
  local session_id="$1"
  local protocol_version="$2"
  local header_file="$3"
  local body_file="$4"

  local -a extra_headers=(
    -H 'Accept: text/event-stream'
    -H "Mcp-Session-Id: $session_id"
  )
  if [ -n "$protocol_version" ]; then
    extra_headers+=(-H "Mcp-Protocol-Version: $protocol_version")
  fi
  if [ -n "$AUTH_HEADER_FILE" ]; then
    extra_headers+=( -H "@$AUTH_HEADER_FILE" )
  fi

  set +e
  curl_with_retry -sS -D "$header_file" -o "$body_file" --max-time 2 \
    "$MCP_URL" \
    "${extra_headers[@]}"
  local curl_status=$?
  set -e
  if [ "$curl_status" -ne 0 ]; then
    return "$curl_status"
  fi
}

delete_with_session() {
  local session_id="$1"
  local protocol_version="$2"
  local header_file="$3"
  local body_file="$4"

  local -a extra_headers=(
    -H "Mcp-Session-Id: $session_id"
  )
  if [ -n "$protocol_version" ]; then
    extra_headers+=(-H "Mcp-Protocol-Version: $protocol_version")
  fi
  if [ -n "$AUTH_HEADER_FILE" ]; then
    extra_headers+=( -H "@$AUTH_HEADER_FILE" )
  fi

  curl_with_retry -sS -D "$header_file" -o "$body_file" \
    -X DELETE "$MCP_URL" \
    "${extra_headers[@]}"
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

require_auth_rejected() {
  local label="$1"
  local header_file="$2"
  local body_file="$3"
  local code
  code="$(status_code "$header_file")"
  case "$code" in
    401|403)
      return 0
      ;;
    *)
      echo "FAIL: expected 401 or 403 for ${label}, got ${code}"
      cat "$header_file"
      cat "$body_file"
      exit 1
      ;;
  esac
}

header_value() {
  local header_file="$1"
  local key="$2"
  awk -v k="$key" '
    tolower($0) ~ "^" tolower(k) ":" {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      sub(/\r$/, "", $0)
      print $0
      exit
    }
  ' "$header_file"
}

wait_for_mcp_ready
echo "[1/11] missing bearer token is rejected"
h0_missing="$tmpdir/auth-missing.headers"
b0_missing="$tmpdir/auth-missing.body"
post_with_accept_auth "application/json, text/event-stream" \
  '{"jsonrpc":"2.0","id":10,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"contract-auth-missing","version":"1.0"},"capabilities":{}}}' \
  "$h0_missing" "$b0_missing" "__NO_AUTH__"
require_auth_rejected "missing bearer token" "$h0_missing" "$b0_missing"

echo "[2/11] malformed authorization header is rejected"
h0_malformed="$tmpdir/auth-malformed.headers"
b0_malformed="$tmpdir/auth-malformed.body"
post_with_accept_auth "application/json, text/event-stream" \
  '{"jsonrpc":"2.0","id":11,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"contract-auth-malformed","version":"1.0"},"capabilities":{}}}' \
  "$h0_malformed" "$b0_malformed" "not-bearer"
require_auth_rejected "malformed authorization header" "$h0_malformed" "$b0_malformed"

echo "[3/11] wrong bearer token is rejected"
h0_wrong="$tmpdir/auth-wrong.headers"
b0_wrong="$tmpdir/auth-wrong.body"
post_with_accept_auth "application/json, text/event-stream" \
  '{"jsonrpc":"2.0","id":12,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"contract-auth-wrong","version":"1.0"},"capabilities":{}}}' \
  "$h0_wrong" "$b0_wrong" "Bearer wrong-token"
require_auth_rejected "wrong bearer token" "$h0_wrong" "$b0_wrong"

echo "[4/11] expired-looking bearer token is rejected"
h0_expired="$tmpdir/auth-expired.headers"
b0_expired="$tmpdir/auth-expired.body"
post_with_accept_auth "application/json, text/event-stream" \
  '{"jsonrpc":"2.0","id":13,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"contract-auth-expired","version":"1.0"},"capabilities":{}}}' \
  "$h0_expired" "$b0_expired" "Bearer expired-token"
require_auth_rejected "expired-looking bearer token" "$h0_expired" "$b0_expired"

echo "[5/11] json-only Accept is rejected"
h1="$tmpdir/json-only-accept.headers"
b1="$tmpdir/json-only-accept.body"
post_with_accept "application/json" \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"contract","version":"1.0"},"capabilities":{}}}' \
  "$h1" "$b1"
code1="$(status_code "$h1")"
if [ "$code1" != "400" ]; then
  echo "FAIL: expected 400 for json-only Accept, got $code1"
  cat "$h1"
  cat "$b1"
  exit 1
fi
if ! grep -qi "Invalid Accept header" "$b1"; then
  echo "FAIL: expected invalid Accept body"
  cat "$b1"
  exit 1
fi

echo "[6/11] streamable Accept success"
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
SESSION_ID="$(header_value "$h2" "Mcp-Session-Id")"
PROTOCOL_VERSION="$(header_value "$h2" "Mcp-Protocol-Version")"
if [ -z "$SESSION_ID" ] || [ -z "$PROTOCOL_VERSION" ]; then
  echo "FAIL: initialize response missing session/protocol headers"
  cat "$h2"
  exit 1
fi

echo "[7/11] follow-up POST accepts missing protocol header via session continuity"
h3="$tmpdir/missing-protocol.headers"
b3="$tmpdir/missing-protocol.body"
post_with_session "$SESSION_ID" "" \
  '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}' \
  "$h3" "$b3"
code3="$(status_code "$h3")"
if [ "$code3" != "200" ]; then
  echo "FAIL: expected 200 for missing protocol header via session continuity, got $code3"
  cat "$h3"
  cat "$b3"
  exit 1
fi

echo "[8/11] follow-up POST rejects mismatched protocol header"
h4="$tmpdir/mismatch-protocol.headers"
b4="$tmpdir/mismatch-protocol.body"
post_with_session "$SESSION_ID" "2025-03-26" \
  '{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{}}' \
  "$h4" "$b4"
code4="$(status_code "$h4")"
if [ "$code4" != "400" ]; then
  echo "FAIL: expected 400 for mismatched protocol header, got $code4"
  cat "$h4"
  cat "$b4"
  exit 1
fi
if ! grep -qi "mismatch" "$b4"; then
  echo "FAIL: expected protocol mismatch body"
  cat "$b4"
  exit 1
fi

echo "[9/11] follow-up POST succeeds with matching protocol header"
h5="$tmpdir/match-protocol.headers"
b5="$tmpdir/match-protocol.body"
post_with_session "$SESSION_ID" "$PROTOCOL_VERSION" \
  '{"jsonrpc":"2.0","id":5,"method":"tools/list","params":{}}' \
  "$h5" "$b5"
code5="$(status_code "$h5")"
if [ "$code5" != "200" ]; then
  echo "FAIL: expected 200 for matching protocol header, got $code5"
  cat "$h5"
  cat "$b5"
  exit 1
fi

echo "[10/11] follow-up GET accepts missing protocol header via session continuity"
h6="$tmpdir/get-missing-protocol.headers"
b6="$tmpdir/get-missing-protocol.body"
get_with_session "$SESSION_ID" "" "$h6" "$b6"
code6="$(status_code "$h6")"
if [ "$code6" != "200" ]; then
  echo "FAIL: expected 200 for GET missing protocol header via session continuity, got $code6"
  cat "$h6"
  cat "$b6"
  exit 1
fi

echo "[11/11] follow-up DELETE accepts missing protocol header via session continuity"
h7="$tmpdir/delete-missing-protocol.headers"
b7="$tmpdir/delete-missing-protocol.body"
delete_with_session "$SESSION_ID" "" "$h7" "$b7"
code7="$(status_code "$h7")"
if [ "$code7" != "200" ] && [ "$code7" != "204" ]; then
  echo "FAIL: expected 200 or 204 for DELETE missing protocol header via session continuity, got $code7"
  cat "$h7"
  cat "$b7"
  exit 1
fi

echo "PASS: streamable_http contract harness"
