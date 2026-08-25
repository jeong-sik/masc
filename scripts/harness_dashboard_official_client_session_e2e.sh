#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD_DIR="${ROOT_DIR}/dashboard"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-5192}"
PROXY_TARGET="${MASC_DASHBOARD_PROXY_TARGET:-http://127.0.0.1:8935}"
FIXTURE_URL="http://${HOST}:${PORT}/dashboard/dev-fixtures/official-client-session-fixture.html"
SERVER_LOG="${TMPDIR:-/tmp}/masc-dashboard-official-client-session-recovery-vite-${PORT}.log"
ARTIFACT_DIR="${OFFICIAL_CLIENT_SESSION_ARTIFACT_DIR:-${TMPDIR:-/tmp}/masc-official-client-session-e2e}"

mkdir -p "${ARTIFACT_DIR}"

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
    sed -n '1,160p' "${SERVER_LOG}" >&2
    exit 1
  fi
  sleep 0.25
done

curl -fsS "${FIXTURE_URL}" >/dev/null
OFFICIAL_CLIENT_SESSION_FIXTURE_URL="${FIXTURE_URL}" \
OFFICIAL_CLIENT_SESSION_ARTIFACT_DIR="${ARTIFACT_DIR}" \
  pnpm --dir "${DASHBOARD_DIR}" exec node e2e/official-client-session.mjs

printf 'Official client session recovery Playwright E2E passed\n'
