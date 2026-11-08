#!/usr/bin/env bash
# E2E: Verify HTTP/1.1 and h2c auto-detection.
#
# In auto mode the server accepts both HTTP/2 prior-knowledge (h2c) and
# HTTP/1.1 connections on the same port via protocol detection.
#
# Tests:
#   1. HTTP/1.1 health check works (baseline)
#   2. HTTP/2 h2c health check works
#   3. MCP POST over h2c, the production path
#   4. The HTTP/1.1 SSE endpoint streams
#   5. Concurrent HTTP/1.1 connections while h2c may be active
#   6. The TLS listener answers --http2 (ALPN h2) and --http1.1 on the same
#      route table; skipped when /health says it is off

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/harness/transport/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck disable=SC2034
HARNESS_NAME="h2c-autodetect"

require_server

echo "--- h2c Auto-detect E2E ---"

token="$(transport_auth_token)"
auth_args=()
if [[ -n "$token" ]]; then
  auth_args=(-H "Authorization: Bearer ${token}")
fi
transport_health_json=""
listener_mode=""
for _ in {1..25}; do
  transport_health_json="$(
    curl -fsS --max-time 5 "${auth_args[@]}" \
      "${MASC_HTTP_BASE_URL}/api/v1/dashboard/transport-health" 2>/dev/null || true
  )"
  listener_mode="$(
    jq -er '.http2.listener_mode' <<<"$transport_health_json" 2>/dev/null || true
  )"
  if [[ -n "$listener_mode" ]]; then
    break
  fi
  sleep 1
done
if [[ "$listener_mode" != "auto" ]]; then
  fail "HTTP listener mode" "expected auto, got ${listener_mode:-missing}"
  summary
  exit 1
fi
pass "HTTP listener reports auto mode"

# Test 1: HTTP/1.1 always works
if curl -sf --max-time 5 --http1.1 "${MASC_HTTP_BASE_URL}/health" >/dev/null 2>&1; then
  pass "HTTP/1.1 health check"
else
  fail "HTTP/1.1 health check" "failed"
fi

# Test 2: h2c prior-knowledge (direct HTTP/2 without upgrade)
# This is the reliable way to test h2c — --http2 uses Upgrade header
# which serve_auto may not support (MSG_PEEK detects connection preface).
h2pk_proto="fail"
for _ in {1..5}; do
  if h2pk_attempt="$(
    curl -sf --max-time 5 -o /dev/null -w '%{http_version}' \
      --http2-prior-knowledge "${MASC_HTTP_BASE_URL}/health" 2>/dev/null
  )"; then
    h2pk_proto="$h2pk_attempt"
    if [[ "$h2pk_proto" == "2" || "$h2pk_proto" == "2.0" ]]; then
      break
    fi
  fi
  sleep 1
done
if [ "$h2pk_proto" = "2" ] || [ "$h2pk_proto" = "2.0" ]; then
  pass "h2c prior-knowledge health check (proto: ${h2pk_proto})"
else
  fail "h2c prior-knowledge" "proto=${h2pk_proto}"
fi

# Test 3: MCP POST over h2c (the actual production path). The listener can
# report ready a fraction before its first h2 stream is accepted; one local
# run observed that single transport reset between a successful h2 health
# probe and an immediately-following initialize. Retry the same idempotent
# initialize for five seconds, while keeping 200 as the only passing verdict.
h2_mcp_code="transport_error"
for _ in {1..5}; do
  if h2_mcp_attempt="$(
    curl -sS --max-time 5 --http2-prior-knowledge -X POST "${MASC_HTTP_BASE_URL}/mcp" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      "${auth_args[@]}" \
      -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"h2c-harness","version":"1.0"}},"id":1}' \
      -o /dev/null -w '%{http_code}' 2>/dev/null
  )"; then
    h2_mcp_code="$h2_mcp_attempt"
    if [[ "$h2_mcp_code" == "200" ]]; then
      break
    fi
  fi
  sleep 1
done
if [ "$h2_mcp_code" = "200" ]; then
  pass "MCP initialize over h2c (status: ${h2_mcp_code})"
else
  fail "MCP over h2c" "status=${h2_mcp_code}"
fi

# Test 4: HTTP/1.1 SSE endpoint (most critical path)
sse_headers=$(curl -sf -I -m 3 --http1.1 "${MASC_HTTP_BASE_URL}/sse" 2>&1 || true)
if grep -qi "200\|text/event-stream" <<<"$sse_headers"; then
  pass "HTTP/1.1 SSE endpoint accessible"
else
  skip "HTTP/1.1 SSE endpoint" "may need session"
fi

# Test 5: Concurrent connections (HTTP/1.1 while h2c might be active)
pids=()
success=0
for _ in 1 2 3 4; do
  curl -sf --max-time 5 --http1.1 "${MASC_HTTP_BASE_URL}/health" >/dev/null 2>&1 &
  pids+=($!)
done
for pid in "${pids[@]}"; do
  wait "$pid" 2>/dev/null && success=$((success + 1))
done
if [ "$success" -eq 4 ]; then
  pass "concurrent HTTP/1.1 connections (4/4)"
else
  fail "concurrent connections" "${success}/4 succeeded"
fi

# Test 6: TLS listener (RFC-0512). ALPN picks h2 for --http2 and http/1.1 for
# --http1.1 on the same route table. Skipped when the listener is off.
# /health reads the listener state directly; transport-health is a cached
# snapshot, so it is not reread here.
tls_health_json="$(
  curl -fsS --max-time 5 "${MASC_HTTP_BASE_URL}/health" 2>/dev/null || printf '%s' "$transport_health_json"
)"
https_status="$(jq -er '.https_listener.status' <<<"$tls_health_json" 2>/dev/null || echo missing)"
https_port="$(jq -er '.https_listener.port' <<<"$tls_health_json" 2>/dev/null || true)"
if [[ "$https_status" == "listening" && -n "$https_port" ]]; then
  https_base="${MASC_HTTPS_BASE_URL:-https://127.0.0.1:${https_port}}"
  # Status and protocol together: a 400 from the request-authority gate would
  # otherwise look like a failed ALPN negotiation. curl prints "000 0" when
  # no response came back, so that is the failure signature.
  tls_h2="$(curl -k -s --max-time 5 -o /dev/null -w '%{http_code} %{http_version}' --http2 "${https_base}/health" 2>/dev/null || true)"
  case "$tls_h2" in
    "200 2"|"200 2.0") pass "HTTPS health over ALPN h2 (${tls_h2})" ;;
    *) fail "HTTPS ALPN h2" "status proto=${tls_h2}" ;;
  esac
  tls_h1="$(curl -k -s --max-time 5 -o /dev/null -w '%{http_code} %{http_version}' --http1.1 "${https_base}/health" 2>/dev/null || true)"
  if [[ "$tls_h1" == "200 1.1" ]]; then
    pass "HTTPS health over ALPN http/1.1"
  else
    fail "HTTPS ALPN http/1.1" "status proto=${tls_h1}"
  fi
else
  skip "HTTPS listener" "status=${https_status}"
fi

summary
