#!/usr/bin/env bash
# Env-gated live WebRTC interop proof.
#
# Scope:
#   - Browser gathers real ICE candidates using configured ICE servers
#   - Server advertises configured ICE server URLs in /health
#   - Server accepts browser-generated candidate strings and completes
#     offer/answer signaling with peer establishment metadata
#
# This is intentionally not a default hermetic gate. It requires:
#   - PLAYWRIGHT_MODULE_PATH or a resolvable playwright install
#   - MASC_WEBRTC_LIVE_ICE_URLS
# Optional:
#   - MASC_WEBRTC_LIVE_ICE_USERNAME / MASC_WEBRTC_LIVE_ICE_CREDENTIAL
#   - MASC_WEBRTC_LIVE_EXPECT_NON_HOST=1 (default)
#   - WEBRTC_LIVE_ARTIFACT_PATH

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
HARNESS_NAME="WebRTC-Live-Env"

PLAYWRIGHT_MODULE_PATH="${PLAYWRIGHT_MODULE_PATH:-}"
MASC_WEBRTC_LIVE_ICE_URLS="${MASC_WEBRTC_LIVE_ICE_URLS:-}"
MASC_WEBRTC_LIVE_ICE_USERNAME="${MASC_WEBRTC_LIVE_ICE_USERNAME:-}"
MASC_WEBRTC_LIVE_ICE_CREDENTIAL="${MASC_WEBRTC_LIVE_ICE_CREDENTIAL:-}"
MASC_WEBRTC_LIVE_EXPECT_NON_HOST="${MASC_WEBRTC_LIVE_EXPECT_NON_HOST:-1}"
WEBRTC_LIVE_ARTIFACT_PATH="${WEBRTC_LIVE_ARTIFACT_PATH:-}"

if [[ -z "$PLAYWRIGHT_MODULE_PATH" ]]; then
  PLAYWRIGHT_MODULE_PATH="$(node -p "try { require.resolve('playwright') } catch { '' }" 2>/dev/null || true)"
fi

if [[ -z "$MASC_WEBRTC_LIVE_ICE_URLS" ]]; then
  echo "SKIP: MASC_WEBRTC_LIVE_ICE_URLS not set"
  exit 0
fi

if [[ -z "$PLAYWRIGHT_MODULE_PATH" ]]; then
  echo "SKIP: Playwright module not found; set PLAYWRIGHT_MODULE_PATH"
  exit 0
fi

# Reuse the same ICE server set for the server unless explicitly overridden.
export MASC_WEBRTC_ICE_URLS="${MASC_WEBRTC_ICE_URLS:-$MASC_WEBRTC_LIVE_ICE_URLS}"
export MASC_WEBRTC_ICE_USERNAME="${MASC_WEBRTC_ICE_USERNAME:-$MASC_WEBRTC_LIVE_ICE_USERNAME}"
export MASC_WEBRTC_ICE_CREDENTIAL="${MASC_WEBRTC_ICE_CREDENTIAL:-$MASC_WEBRTC_LIVE_ICE_CREDENTIAL}"

require_server

echo "--- WebRTC Live Env Interop ---"

health_json="$(curl -fsS "${MASC_HTTP_BASE_URL}/health")"
health_check="$(
  HEALTH_JSON="$health_json" EXPECTED_URLS="$MASC_WEBRTC_ICE_URLS" python3 - <<'PY'
import json, os, sys
payload = json.loads(os.environ["HEALTH_JSON"])
actual = payload["transport"]["webrtc"].get("ice_server_urls", [])
expected = [s.strip() for s in os.environ["EXPECTED_URLS"].split(",") if s.strip()]
ok = all(url in actual for url in expected)
print(json.dumps({"ok": ok, "actual": actual, "expected": expected}))
PY
)"
if HEALTH_CHECK="$health_check" python3 - <<'PY'
import json, os, sys
sys.exit(0 if json.loads(os.environ["HEALTH_CHECK"])["ok"] else 1)
PY
then
  pass "health exposes configured ICE server URLs"
else
  fail "health ICE server URLs" "$health_check"
  summary
  exit 1
fi

browser_artifact="$(mktemp "${TMPDIR:-/tmp}/masc-webrtc-live-browser.XXXXXX.json")"
PLAYWRIGHT_MODULE_PATH="$PLAYWRIGHT_MODULE_PATH" \
MASC_WEBRTC_LIVE_ICE_URLS="$MASC_WEBRTC_LIVE_ICE_URLS" \
MASC_WEBRTC_LIVE_ICE_USERNAME="$MASC_WEBRTC_LIVE_ICE_USERNAME" \
MASC_WEBRTC_LIVE_ICE_CREDENTIAL="$MASC_WEBRTC_LIVE_ICE_CREDENTIAL" \
MASC_WEBRTC_LIVE_EXPECT_NON_HOST="$MASC_WEBRTC_LIVE_EXPECT_NON_HOST" \
node <<'NODE' >"$browser_artifact"
const { chromium } = require(process.env.PLAYWRIGHT_MODULE_PATH);

const urls = process.env.MASC_WEBRTC_LIVE_ICE_URLS.split(',').map(s => s.trim()).filter(Boolean);
const username = process.env.MASC_WEBRTC_LIVE_ICE_USERNAME || undefined;
const credential = process.env.MASC_WEBRTC_LIVE_ICE_CREDENTIAL || undefined;
const expectNonHost = process.env.MASC_WEBRTC_LIVE_EXPECT_NON_HOST !== '0';

async function main() {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  const result = await page.evaluate(async ({ urls, username, credential, expectNonHost }) => {
    const iceServers = [{ urls, username, credential }];
    const pc = new RTCPeerConnection({ iceServers });
    pc.createDataChannel('live-env');
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    await new Promise(resolve => {
      if (pc.iceGatheringState === 'complete') return resolve();
      const timeout = setTimeout(resolve, 15000);
      pc.addEventListener('icegatheringstatechange', () => {
        if (pc.iceGatheringState === 'complete') {
          clearTimeout(timeout);
          resolve();
        }
      });
    });

    const sdp = pc.localDescription?.sdp || '';
    const lines = sdp.split(/\r?\n/);
    const candidates = lines.filter(line => line.startsWith('a=candidate:') || line.startsWith('candidate:'));
    const fingerprintLine = lines.find(line => line.startsWith('a=fingerprint:')) || '';
    const fingerprint = fingerprintLine.replace(/^a=fingerprint:/, '').trim();
    const hasNonHost = candidates.some(line => /\btyp (srflx|relay)\b/.test(line));
    await pc.close();
    return {
      candidateCount: candidates.length,
      candidates,
      fingerprint,
      hasNonHost,
      expectNonHost,
      urls,
    };
  }, { urls, username, credential, expectNonHost });
  await browser.close();
  console.log(JSON.stringify(result));
}

main().catch(err => {
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
NODE

browser_check="$(
  BROWSER_ARTIFACT="$browser_artifact" python3 - <<'PY'
import json, os, sys
payload = json.load(open(os.environ["BROWSER_ARTIFACT"], "r", encoding="utf-8"))
ok = payload["candidateCount"] > 0 and bool(payload["fingerprint"])
if ok and payload["expectNonHost"]:
    ok = payload["hasNonHost"]
print(json.dumps({"ok": ok, **payload}))
PY
)"
if BROWSER_CHECK="$browser_check" python3 - <<'PY'
import json, os, sys
sys.exit(0 if json.loads(os.environ["BROWSER_CHECK"])["ok"] else 1)
PY
then
  pass "browser gathered live ICE candidates"
else
  fail "browser ICE gather" "$browser_check"
  summary
  exit 1
fi

offer_payload="$(mktemp "${TMPDIR:-/tmp}/masc-webrtc-live-offer.XXXXXX.json")"
BROWSER_ARTIFACT="$browser_artifact" python3 - <<'PY' >"$offer_payload"
import json, os
browser = json.load(open(os.environ["BROWSER_ARTIFACT"], "r", encoding="utf-8"))
print(json.dumps({
    "agent_name": "webrtc-live-browser",
    "ice_candidates": browser["candidates"],
    "dtls_fingerprint": browser["fingerprint"],
}))
PY

offer_resp="$(curl -fsS -X POST "${MASC_HTTP_BASE_URL}/webrtc/offer" -H "Content-Type: application/json" --data @"$offer_payload")"
offer_id="$(
  OFFER_JSON="$offer_resp" python3 - <<'PY'
import json, os
print(json.loads(os.environ["OFFER_JSON"]).get("offer_id", ""))
PY
)"
if [[ -n "$offer_id" && "$offer_id" != "null" ]]; then
  pass "server accepted browser-style offer: ${offer_id}"
else
  fail "server accepted browser-style offer" "${offer_resp:0:200}"
  summary
  exit 1
fi

answer_resp="$(curl -fsS -X POST "${MASC_HTTP_BASE_URL}/webrtc/answer" \
  -H "Content-Type: application/json" \
  -d "{\"offer_id\":\"${offer_id}\",\"agent_name\":\"webrtc-live-server\"}")"
answer_check="$(
  ANSWER_JSON="$answer_resp" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["ANSWER_JSON"])
ok = bool(payload.get("peer_id")) and bool(payload.get("ice_ufrag")) and bool(payload.get("ice_pwd"))
print(json.dumps({"ok": ok, **payload}))
PY
)"
if ANSWER_CHECK="$answer_check" python3 - <<'PY'
import json, os, sys
sys.exit(0 if json.loads(os.environ["ANSWER_CHECK"])["ok"] else 1)
PY
then
  pass "server completed live env offer/answer signaling"
else
  fail "server completed live env offer/answer signaling" "$answer_check"
fi

if [[ -n "$WEBRTC_LIVE_ARTIFACT_PATH" ]]; then
  mkdir -p "$(dirname "$WEBRTC_LIVE_ARTIFACT_PATH")"
  HEALTH_CHECK="$health_check" BROWSER_CHECK="$browser_check" ANSWER_CHECK="$answer_check" python3 - <<'PY' >"$WEBRTC_LIVE_ARTIFACT_PATH"
import json, os
artifact = {
    "health": json.loads(os.environ["HEALTH_CHECK"]),
    "browser": json.loads(os.environ["BROWSER_CHECK"]),
    "answer": json.loads(os.environ["ANSWER_CHECK"]),
}
print(json.dumps(artifact, indent=2, sort_keys=True))
PY
  pass "artifact written: ${WEBRTC_LIVE_ARTIFACT_PATH}"
fi

rm -f "$browser_artifact" "$offer_payload"

summary
