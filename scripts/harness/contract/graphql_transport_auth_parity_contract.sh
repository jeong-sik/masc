#!/usr/bin/env bash
# /graphql must apply the same read gate on HTTP/1.1 and on HTTP/2.
#
# Both transports are served on one port: serve_auto sniffs the connection
# preface and hands h2c connections to Server_h2_gateway and everything else to
# the HTTP/1 router (server_bootstrap_http.ml). The two route tables are
# maintained by hand, so an auth wrapper present on one side and absent on the
# other turns the client's protocol choice into an authorization decision.
#
# That is what this contract exists to catch: POST /graphql executed
# unauthenticated over h2c while the same request was rejected with 401 over
# HTTP/1.
set -euo pipefail

: "${MCP_URL:=http://127.0.0.1:8935/mcp}"
: "${BASE_PATH:?BASE_PATH must be set by run_all.sh}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/harness/lib/test_framework.sh
source "${SCRIPT_DIR}/../lib/test_framework.sh"

BASE_URL="${MCP_URL%/mcp}"
GRAPHQL_URL="${BASE_URL}/graphql"
QUERY='{"query":"{ __typename }"}'

if ! curl --version | grep -qi 'HTTP2'; then
  echo "FAIL: curl lacks HTTP/2 support; this contract cannot prove transport parity" >&2
  exit 1
fi

# Issues exactly one unauthenticated POST on the named transport and echoes
# "<http_code> <body>". Each transport is probed once: re-probing to compare
# statuses would double the request count and let a rate limiter answer a later
# probe instead of the auth gate.
unauthenticated_post() {
  local transport="$1"
  local body_file="$2"
  local -a curl_args=( --http1.1 )
  if [[ "$transport" == "h2" ]]; then
    curl_args=( --http2-prior-knowledge )
  fi
  local status attempt
  # A transport error is a distinct outcome from "the server answered", and it
  # is not evidence about the authorization gate this contract tests. Retry the
  # connection once so a dropped socket does not read as an auth verdict; never
  # retry on an HTTP status, which IS the signal. Report loudly if both
  # attempts fail rather than letting `set -e` kill the run with no diagnosis.
  for attempt in 1 2; do
    if status="$(curl -s -o "$body_file" -w '%{http_code}' \
        --max-time "${CURL_TIMEOUT_SEC:-25}" "${curl_args[@]}" \
        -X POST -H 'content-type: application/json' -d "$QUERY" "$GRAPHQL_URL")"; then
      echo "$status"
      return 0
    fi
    if [[ "$attempt" == 1 ]]; then
      echo "  note: POST /graphql over ${transport} failed to connect; retrying once" >&2
      sleep 1
    fi
  done
  echo "FAIL: POST /graphql over ${transport} did not complete (curl error, 2 attempts)" >&2
  exit 1
}

H1_BODY="$(mcp_mktemp_file "masc-graphql-parity-h1" ".json")"
H2_BODY="$(mcp_mktemp_file "masc-graphql-parity-h2" ".json")"

echo "[1/3] HTTP/1.1 answers an unauthenticated POST /graphql"
H1_STATUS="$(unauthenticated_post h1 "$H1_BODY")"
echo "  h1 status=${H1_STATUS}"

echo "[2/3] HTTP/2 answers an unauthenticated POST /graphql"
H2_STATUS="$(unauthenticated_post h2 "$H2_BODY")"
echo "  h2 status=${H2_STATUS}"

echo "[3/3] neither transport executes the query, and both answer alike"
for probe in "h1 ${H1_STATUS} ${H1_BODY}" "h2 ${H2_STATUS} ${H2_BODY}"; do
  read -r transport status body_file <<<"$probe"
  # 2xx means the query ran for a caller that presented no credential.
  if [[ "$status" == 2* ]]; then
    mcp_fail_with_context \
      "unauthenticated POST /graphql was accepted over ${transport}" \
      "$(jq -cn --arg transport "$transport" --arg status "$status" \
        --arg body "$(head -c 400 "$body_file")" \
        '{transport:$transport,status:$status,body:$body}')"
  fi
done

# Parity, not merely "both non-2xx": a transport that 404s while the other 401s
# would clear the loop above while proving nothing about the gate.
if [[ "$H1_STATUS" != "$H2_STATUS" ]]; then
  mcp_fail_with_context \
    "POST /graphql answered unauthenticated callers differently per transport" \
    "$(jq -cn --arg h1 "$H1_STATUS" --arg h2 "$H2_STATUS" '{h1:$h1,h2:$h2}')"
fi

echo "PASS: graphql transport auth parity (h1=${H1_STATUS} h2=${H2_STATUS})"
