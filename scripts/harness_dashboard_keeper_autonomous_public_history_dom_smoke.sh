#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD_DIR="${ROOT_DIR}/dashboard"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-5188}"
FIXTURE_URL="http://${HOST}:${PORT}/dashboard/dev-fixtures/keeper-autonomous-public-history-fixture.html"
SERVER_LOG="${TMPDIR:-/tmp}/masc-autonomous-public-history-vite-${PORT}.log"
SCREENSHOT="${TMPDIR:-/tmp}/masc-autonomous-public-history-expanded.png"

server_pid=""
cleanup() {
  if [[ -n "${server_pid}" ]] && kill -0 "${server_pid}" 2>/dev/null; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

MASC_DASHBOARD_PROXY_TARGET="http://127.0.0.1:8935" \
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

PLAYWRIGHT_PYTHON="${PLAYWRIGHT_PYTHON:-}"
PLAYWRIGHT_PYTHON_CMD=()
if [[ -n "${PLAYWRIGHT_PYTHON}" ]]; then
  PLAYWRIGHT_PYTHON_CMD=("${PLAYWRIGHT_PYTHON}")
elif pnpm --dir "${DASHBOARD_DIR}" exec python3 -c 'import playwright' >/dev/null 2>&1; then
  PLAYWRIGHT_PYTHON_CMD=(pnpm --dir "${DASHBOARD_DIR}" exec python3)
elif python3 -c 'import playwright' >/dev/null 2>&1; then
  PLAYWRIGHT_PYTHON_CMD=(python3)
else
  echo "Python Playwright module not found. Set PLAYWRIGHT_PYTHON=/abs/path/to/python with playwright installed." >&2
  exit 1
fi

FIXTURE_URL="${FIXTURE_URL}" SCREENSHOT="${SCREENSHOT}" \
  "${PLAYWRIGHT_PYTHON_CMD[@]}" - <<'PY'
import os
from playwright.sync_api import sync_playwright

url = os.environ["FIXTURE_URL"]
screenshot = os.environ["SCREENSHOT"]
with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True)
    try:
        page = browser.new_page(viewport={"width": 1440, "height": 900})
        page.goto(url, wait_until="domcontentloaded", timeout=30_000)
        page.locator('[data-autonomous-public-history-fixture-status="ok"]').wait_for()
        group = page.locator('.chat-block-trace-hd', has_text='자율턴')
        assert group.get_attribute("aria-expanded") == "false"
        before = page.locator("body").inner_text()
        assert "PRIVATE_THINKING_MUST_NOT_RENDER" not in before
        assert "PRIVATE_TOOL_ARG" not in before
        group.click()
        assert group.get_attribute("aria-expanded") == "true"
        page.get_by_text("Checked the board; no action was required.", exact=True).last.wait_for()
        page.get_by_text("Observed one healthy follow-up.", exact=True).last.wait_for()
        after = page.locator("body").inner_text()
        assert "PRIVATE_THINKING_MUST_NOT_RENDER" not in after
        assert "PRIVATE_TOOL_ARG" not in after
        page.screenshot(path=screenshot, full_page=True)
    finally:
        browser.close()
PY

printf 'autonomous public history interaction passed\n'
printf 'screenshot=%s\n' "${SCREENSHOT}"
