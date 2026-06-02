#!/usr/bin/env bash
# E2E: Verify WebRTC signaling HTTP endpoints.
#
# Tests:
#   1. /health reports WebRTC enabled
#   2. Offer creation succeeds with browser-style ICE candidate strings
#   3. Answer acceptance returns peer_id plus ICE credentials
#   4. Duplicate accept is rejected
#   5. Invalid offer_id is rejected

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
HARNESS_NAME="WebRTC-Signaling"

require_server

echo "--- WebRTC Signaling E2E ---"

health_resp="$(curl -fsS "${MASC_HTTP_BASE_URL}/health")"
webrtc_enabled="$(
  HEALTH_JSON="$health_resp" python3 - <<'PY'
import json, os
print(str(json.loads(os.environ["HEALTH_JSON"])["transport"]["webrtc"]["enabled"]).lower())
PY
)"
if [[ "$webrtc_enabled" = "true" ]]; then
  pass "health reports WebRTC enabled"
else
  fail "health reports WebRTC enabled" "webrtc.enabled=false"
  summary
  exit 1
fi

offer_resp="$(
  curl -fsS -X POST "${MASC_HTTP_BASE_URL}/webrtc/offer" \
    -H "Content-Type: application/json" \
    -d '{"agent_name":"e2e-tester","ice_candidates":["candidate:842163049 1 udp 1677729535 127.0.0.1 50000 typ srflx raddr 0.0.0.0 rport 9"],"dtls_fingerprint":"sha256:abc"}'
)"
offer_id="$(
  OFFER_JSON="$offer_resp" python3 - <<'PY'
import json, os
print(json.loads(os.environ["OFFER_JSON"]).get("offer_id", ""))
PY
)"
if [[ -n "$offer_id" && "$offer_id" != "null" ]]; then
  pass "offer created: ${offer_id}"
else
  fail "offer creation" "unexpected response: ${offer_resp:0:160}"
  summary
  exit 1
fi

answer_resp="$(
  curl -fsS -X POST "${MASC_HTTP_BASE_URL}/webrtc/answer" \
    -H "Content-Type: application/json" \
    -d "{\"offer_id\":\"${offer_id}\",\"agent_name\":\"e2e-answerer\",\"ice_candidates\":[\"candidate:1 1 udp 2130706431 127.0.0.1 50001 typ host\"]}"
)"
read -r peer_id ice_ufrag ice_pwd <<EOF
$(ANSWER_JSON="$answer_resp" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["ANSWER_JSON"])
print(payload.get("peer_id", ""), payload.get("ice_ufrag", ""), payload.get("ice_pwd", ""))
PY
)
EOF
if [[ -n "$peer_id" && -n "$ice_ufrag" && -n "$ice_pwd" ]]; then
  pass "offer accepted, peer established: ${peer_id}"
else
  fail "offer acceptance" "unexpected response: ${answer_resp:0:200}"
fi

dup_resp="$(
  curl -fsS -X POST "${MASC_HTTP_BASE_URL}/webrtc/answer" \
    -H "Content-Type: application/json" \
    -d "{\"offer_id\":\"${offer_id}\",\"agent_name\":\"e2e-dup\"}" 2>&1 || true
)"
if echo "$dup_resp" | grep -qi "not found\|expired\|error"; then
  pass "duplicate accept correctly rejected"
else
  fail "duplicate accept" "should have failed: ${dup_resp:0:160}"
fi

invalid_resp="$(
  curl -fsS -X POST "${MASC_HTTP_BASE_URL}/webrtc/answer" \
    -H "Content-Type: application/json" \
    -d '{"offer_id":"nonexistent-id","agent_name":"e2e-invalid"}' 2>&1 || true
)"
if echo "$invalid_resp" | grep -qi "not found\|error"; then
  pass "invalid offer_id rejected"
else
  fail "invalid offer_id" "should have failed: ${invalid_resp:0:160}"
fi

summary
