#!/usr/bin/env bash
set -euo pipefail

MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
BASE_URL="${MCP_URL%/mcp}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/harness/lib/mcp_jsonrpc.sh
source "${SCRIPT_DIR}/../lib/mcp_jsonrpc.sh"

tmpdir="$(mktemp -d)"
AUTH_TOKEN="$(mcp_default_auth_token)"
AUTH_HEADER_FILE=""
if [[ -n "$AUTH_TOKEN" ]]; then
  AUTH_HEADER_FILE="$tmpdir/auth.header"
  printf 'Authorization: Bearer %s\n' "$AUTH_TOKEN" >"$AUTH_HEADER_FILE"
fi
trap 'rm -rf "$tmpdir"' EXIT

status_code() {
  awk 'toupper($1) ~ /^HTTP\/[0-9.]+$/ { code=$2 } END { print code }' "$1"
}

current_body() {
  local id="$1" method="$2" params="$3"
  MCP_PROTOCOL_VERSION=2026-07-28 _mcp_build_request_body "$id" "$method" "$params"
}

post_request() {
  local label="$1" accept="$2" method="$3" params="$4" auth="$5"
  # ${6-...} (not ${6:-...}): an explicitly empty 6th argument must stay empty
  # so case [5/7] can omit the Mcp-Protocol-Version header entirely; only an
  # unset argument falls back to the default version.
  local protocol_header="${6-2026-07-28}"
  local body header_file body_file request_name
  header_file="$tmpdir/${label}.headers"
  body_file="$tmpdir/${label}.body"
  body="$(current_body 1 "$method" "$params")"
  local -a headers=(
    -H 'Content-Type: application/json'
    -H "Accept: $accept"
    -H "Mcp-Method: $method"
  )
  if [[ -n "$protocol_header" ]]; then
    headers+=( -H "Mcp-Protocol-Version: $protocol_header" )
  fi
  case "$method" in
    tools/call|prompts/get)
      request_name="$(jq -r '.name' <<<"$params")"
      headers+=( -H "Mcp-Name: $request_name" )
      ;;
    resources/read)
      request_name="$(jq -r '.uri' <<<"$params")"
      headers+=( -H "Mcp-Name: $request_name" )
      ;;
  esac
  case "$auth" in
    default)
      [[ -z "$AUTH_HEADER_FILE" ]] || headers+=( -H "@$AUTH_HEADER_FILE" )
      ;;
    none) ;;
    *) headers+=( -H "Authorization: $auth" ) ;;
  esac
  curl -sS --max-time "${CURL_TIMEOUT_SEC:-25}" -D "$header_file" -o "$body_file" \
    -X POST "$MCP_URL" "${headers[@]}" --data-binary "$body"
  printf '%s\t%s\n' "$header_file" "$body_file"
}

require_status() {
  local expected="$1" header_file="$2" body_file="$3"
  local actual
  actual="$(status_code "$header_file")"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: expected HTTP $expected, got ${actual:-<missing>}" >&2
    cat "$header_file" "$body_file" >&2
    exit 1
  fi
}

require_auth_rejected() {
  local header_file="$1" body_file="$2" code
  code="$(status_code "$header_file")"
  case "$code" in
    401|403) ;;
    *)
      echo "FAIL: expected authentication rejection, got ${code:-<missing>}" >&2
      cat "$header_file" "$body_file" >&2
      exit 1
      ;;
  esac
}

deadline=$(( $(date +%s) + ${MCP_READY_TIMEOUT_SEC:-20} ))
until curl -fsS --max-time 2 "$BASE_URL/health" >/dev/null 2>&1; do
  if [[ "$(date +%s)" -ge "$deadline" ]]; then
    echo "FAIL: MCP server did not become ready at $BASE_URL" >&2
    exit 1
  fi
  sleep 1
done

tools_params='{}'

echo "[1/7] missing bearer token is rejected"
IFS=$'\t' read -r headers body < <(post_request auth-missing 'application/json, text/event-stream' tools/list "$tools_params" none)
require_auth_rejected "$headers" "$body"

echo "[2/7] malformed authorization header is rejected"
IFS=$'\t' read -r headers body < <(post_request auth-malformed 'application/json, text/event-stream' tools/list "$tools_params" not-bearer)
require_auth_rejected "$headers" "$body"

echo "[3/7] wrong bearer token is rejected"
IFS=$'\t' read -r headers body < <(post_request auth-wrong 'application/json, text/event-stream' tools/list "$tools_params" 'Bearer wrong-token')
require_auth_rejected "$headers" "$body"

echo "[4/7] json-only Accept is rejected"
IFS=$'\t' read -r headers body < <(post_request json-only application/json tools/list "$tools_params" default)
require_status 400 "$headers" "$body"
grep -qi 'Invalid Accept header' "$body" || { echo "FAIL: missing Accept rejection" >&2; exit 1; }

echo "[5/7] missing protocol header is rejected"
IFS=$'\t' read -r headers body < <(post_request protocol-missing 'application/json, text/event-stream' tools/list "$tools_params" default '')
require_status 400 "$headers" "$body"
grep -qi 'missing MCP-Protocol-Version' "$body" || { echo "FAIL: missing protocol rejection" >&2; exit 1; }

echo "[6/7] unsupported protocol header is rejected"
IFS=$'\t' read -r headers body < <(post_request protocol-unsupported 'application/json, text/event-stream' tools/list "$tools_params" default unsupported-version)
require_status 400 "$headers" "$body"
grep -qi 'Unsupported protocol version' "$body" || { echo "FAIL: missing unsupported-version rejection" >&2; exit 1; }

echo "[7/7] current stateless tools/list succeeds"
IFS=$'\t' read -r headers body < <(post_request tools-list 'application/json, text/event-stream' tools/list "$tools_params" default)
require_status 200 "$headers" "$body"
jq -e '.result.resultType == "complete" and (.result.tools | length > 0)' "$body" >/dev/null

echo "PASS: current streamable_http contract harness"
