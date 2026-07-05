#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD_DIR="${ROOT_DIR}/dashboard"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-5184}"
PROXY_TARGET="${MASC_DASHBOARD_PROXY_TARGET:-http://127.0.0.1:8935}"
FIXTURE_URL="http://${HOST}:${PORT}/dashboard/dev-fixtures/keeper-chat-replay-contract-fixture.html"
SERVER_LOG="${TMPDIR:-/tmp}/masc-dashboard-replay-contract-vite-${PORT}.log"
DESKTOP_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-replay-contract-fixture-desktop.png"
MOBILE_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-replay-contract-fixture-mobile.png"
SERVER_REPLAY_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-replay-contract-server-replay.png"
NO_TURN_REF_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-replay-contract-no-turn-ref.png"
QUEUE_PLACEHOLDER_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-replay-contract-queue-placeholder.png"
QUEUE_RESULT_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-replay-contract-queue-result.png"
LIVE_TERMINAL_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-replay-contract-live-terminal.png"

STATUS_SELECTOR='[data-replay-contract-fixture-status="ok"][data-replay-contract-fixture-row-count="6"][data-replay-contract-fixture-client-observed-count="1"][data-replay-contract-fixture-no-delivery-count="4"][data-replay-contract-fixture-server-replay-count="1"]'
SERVER_REPLAY_SELECTOR='[data-chat-entry-id="smoke-error-assistant"][data-chat-stream-contract-badge-state="server-replay"][data-chat-stream-contract-event="RUN_ERROR"][data-chat-stream-contract-delivery-receipt="server_lifecycle_replay_only"] [data-chat-stream-contract-badge="server-replay"]'
NO_TURN_REF_SELECTOR='[data-chat-entry-id="smoke-legacy-user"][data-chat-stream-contract-badge-state="no-turn-ref"][data-chat-stream-contract-status="history_without_turn_ref"][data-chat-stream-contract-delivery-receipt="no_delivery_receipt"] [data-chat-stream-contract-badge="no-turn-ref"]'
QUEUE_PLACEHOLDER_SELECTOR='[data-chat-entry-id="smoke-queued-assistant"][data-chat-delivery-state="queued"][data-chat-stream-state="opening"][data-chat-stream-contract-source="pending_request_store"][data-chat-stream-contract-status="client_placeholder"][data-chat-stream-contract-request-id="req-chat-contract-smoke-1"][data-chat-stream-contract-delivery-receipt="no_delivery_receipt"]'
QUEUE_RESULT_SELECTOR='[data-chat-entry-id="smoke-queue-result-assistant"][data-chat-delivery-state="delivered"][data-chat-stream-contract-source="queue_poll"][data-chat-stream-contract-status="queue_poll_result"][data-chat-stream-contract-request-id="req-chat-contract-smoke-1"][data-chat-stream-contract-delivery-receipt="no_delivery_receipt"]'
LIVE_TERMINAL_SELECTOR='[data-chat-entry-id="smoke-live-final-assistant"][data-chat-delivery-state="delivered"][data-chat-stream-contract-source="sse_event"][data-chat-stream-contract-status="backend_terminal_event"][data-chat-stream-contract-event="RUN_FINISHED"][data-chat-stream-contract-delivery-receipt="client_observed_sse_event"]'

server_pid=""
cleanup() {
  if [[ -n "${server_pid}" ]] && kill -0 "${server_pid}" 2>/dev/null; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

pnpm --dir "${DASHBOARD_DIR}" exec playwright --version >/dev/null

MASC_DASHBOARD_PROXY_TARGET="${PROXY_TARGET}" \
  pnpm --dir "${DASHBOARD_DIR}" exec vite --host "${HOST}" --port "${PORT}" --strictPort \
  >"${SERVER_LOG}" 2>&1 &
server_pid="$!"

for _ in {1..80}; do
  if curl -fsS "${FIXTURE_URL}" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "${server_pid}" 2>/dev/null; then
    cat "${SERVER_LOG}" >&2
    exit 1
  fi
  sleep 0.25
done

curl -fsS "${FIXTURE_URL}" >/dev/null

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 1440,900 \
  --timeout 30000 \
  --wait-for-selector "${STATUS_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${DESKTOP_SCREENSHOT}"

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 1440,900 \
  --timeout 30000 \
  --wait-for-selector "${SERVER_REPLAY_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${SERVER_REPLAY_SCREENSHOT}"

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 1440,900 \
  --timeout 30000 \
  --wait-for-selector "${NO_TURN_REF_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${NO_TURN_REF_SCREENSHOT}"

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 1440,900 \
  --timeout 30000 \
  --wait-for-selector "${QUEUE_PLACEHOLDER_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${QUEUE_PLACEHOLDER_SCREENSHOT}"

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 1440,900 \
  --timeout 30000 \
  --wait-for-selector "${QUEUE_RESULT_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${QUEUE_RESULT_SCREENSHOT}"

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 1440,900 \
  --timeout 30000 \
  --wait-for-selector "${LIVE_TERMINAL_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${LIVE_TERMINAL_SCREENSHOT}"

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 390,844 \
  --timeout 30000 \
  --wait-for-selector "${STATUS_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${MOBILE_SCREENSHOT}"

printf 'keeper chat replay contract DOM smoke passed\n'
printf 'fixture_url=%s\n' "${FIXTURE_URL}"
printf 'desktop_screenshot=%s\n' "${DESKTOP_SCREENSHOT}"
printf 'mobile_screenshot=%s\n' "${MOBILE_SCREENSHOT}"
printf 'queue_placeholder_screenshot=%s\n' "${QUEUE_PLACEHOLDER_SCREENSHOT}"
printf 'queue_result_screenshot=%s\n' "${QUEUE_RESULT_SCREENSHOT}"
printf 'live_terminal_screenshot=%s\n' "${LIVE_TERMINAL_SCREENSHOT}"
