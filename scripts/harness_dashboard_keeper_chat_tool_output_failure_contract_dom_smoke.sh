#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD_DIR="${ROOT_DIR}/dashboard"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-5187}"
PROXY_TARGET="${MASC_DASHBOARD_PROXY_TARGET:-http://127.0.0.1:8935}"
FIXTURE_URL="http://${HOST}:${PORT}/dashboard/dev-fixtures/keeper-chat-tool-output-failure-contract-fixture.html"
SERVER_LOG="${TMPDIR:-/tmp}/masc-dashboard-tool-output-failure-contract-vite-${PORT}.log"
DESKTOP_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-tool-output-failure-contract-fixture-desktop.png"
MOBILE_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-tool-output-failure-contract-fixture-mobile.png"
HYDRATION_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-tool-output-failure-contract-hydration-failed.png"
COVERAGE_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-tool-output-failure-contract-coverage-gap.png"
HYDRATION_EXPANDED_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-tool-output-failure-contract-hydration-expanded.png"
COVERAGE_EXPANDED_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-tool-output-failure-contract-coverage-expanded.png"
MOBILE_EXPANDED_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-tool-output-failure-contract-mobile-expanded.png"
BROWSER_SCRIPT="${TMPDIR:-/tmp}/masc-chat-tool-output-failure-contract-interaction-${PORT}.py"

HYDRATION_SIGNATURE='tool:tc-hydration-failed|chat:assistant-hydration-failed'
COVERAGE_SIGNATURE='tool:tc-coverage-gap|chat:assistant-coverage-gap'
STATUS_SELECTOR='[data-tool-output-failure-contract-fixture-status="ok"][data-tool-output-failure-hydration-failed-count="1"][data-tool-output-failure-coverage-gap-count="1"]'
HYDRATION_TRACE_SELECTOR="[data-tool-output-failure-scenario=\"hydration-failed\"] [data-chat-work-trace][data-chat-turn-order-signature=\"${HYDRATION_SIGNATURE}\"][data-chat-tool-output-hydration-source=\"tool_calls_endpoint\"][data-chat-tool-output-hydration-status=\"failed\"][data-chat-tool-output-hydration-failure=\"tool_calls_endpoint_502\"]"
HYDRATION_TOOL_SELECTOR='[data-tool-output-failure-scenario="hydration-failed"] [data-chat-trace-step="tool"][data-chat-turn-order-index="0"][data-chat-turn-order-kind="tool"][data-chat-trace-tool-call-id="tc-hydration-failed"][data-chat-trace-entry-id="tool-tc-hydration-failed"][data-chat-trace-link-state="joined"][data-chat-trace-output-state="hydration-failed"][data-chat-trace-output-coverage="hydration-failed"]'
COVERAGE_TRACE_SELECTOR="[data-tool-output-failure-scenario=\"coverage-gap\"] [data-chat-work-trace][data-chat-turn-order-signature=\"${COVERAGE_SIGNATURE}\"][data-chat-tool-output-hydration-source=\"tool_calls_endpoint\"][data-chat-tool-output-hydration-status=\"hydrated\"][data-chat-tool-output-covered-through=\"1783264270000\"]"
COVERAGE_TOOL_SELECTOR='[data-tool-output-failure-scenario="coverage-gap"] [data-chat-trace-step="tool"][data-chat-turn-order-index="0"][data-chat-turn-order-kind="tool"][data-chat-trace-tool-call-id="tc-coverage-gap"][data-chat-trace-entry-id="tool-tc-coverage-gap"][data-chat-trace-link-state="joined"][data-chat-trace-output-state="coverage-gap"][data-chat-trace-output-coverage="coverage-gap"]'

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
  --wait-for-selector "${HYDRATION_TRACE_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${HYDRATION_SCREENSHOT}"

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 1440,900 \
  --timeout 30000 \
  --wait-for-selector "${HYDRATION_TOOL_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${HYDRATION_SCREENSHOT}"

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 1440,900 \
  --timeout 30000 \
  --wait-for-selector "${COVERAGE_TRACE_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${COVERAGE_SCREENSHOT}"

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 1440,900 \
  --timeout 30000 \
  --wait-for-selector "${COVERAGE_TOOL_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${COVERAGE_SCREENSHOT}"

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 390,844 \
  --timeout 30000 \
  --wait-for-selector "${STATUS_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${MOBILE_SCREENSHOT}"

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

cat >"${BROWSER_SCRIPT}" <<'PY'
import os
from playwright.sync_api import sync_playwright

fixture_url = os.environ["FIXTURE_URL"]
hydration_expanded_screenshot = os.environ["HYDRATION_EXPANDED_SCREENSHOT"]
coverage_expanded_screenshot = os.environ["COVERAGE_EXPANDED_SCREENSHOT"]
mobile_expanded_screenshot = os.environ["MOBILE_EXPANDED_SCREENSHOT"]
status_selector = '[data-tool-output-failure-contract-fixture-status="ok"][data-tool-output-failure-hydration-failed-count="1"][data-tool-output-failure-coverage-gap-count="1"]'
hydration_tool_selector = '[data-tool-output-failure-scenario="hydration-failed"] [data-chat-trace-step="tool"][data-chat-trace-output-state="hydration-failed"][data-chat-trace-output-coverage="hydration-failed"]'
coverage_tool_selector = '[data-tool-output-failure-scenario="coverage-gap"] [data-chat-trace-step="tool"][data-chat-trace-output-state="coverage-gap"][data-chat-trace-output-coverage="coverage-gap"]'
hydration_explanation = '출력 hydration 실패 — tool_calls_endpoint_502'
coverage_explanation = '출력 tail 범위 밖'
expected_title = 'MASC - Keeper Chat Tool Output Failure Contract Fixture'


def assert_visible_text(page, text):
    page.wait_for_function(
        "expected => document.body.innerText.includes(expected)",
        arg=text,
        timeout=10_000,
    )


def open_tool(page, selector):
    page.locator(f"{selector} .chat-block-tstep-row").click()


def verify_page_health(page):
    page.goto(fixture_url, wait_until="domcontentloaded", timeout=20_000)
    page.wait_for_selector(status_selector, timeout=15_000)
    title = page.title()
    if title != expected_title:
        raise RuntimeError(f"unexpected title: {title}")
    body_text = page.locator("body").inner_text()
    if "Tool output failures are explicit" not in body_text:
        raise RuntimeError("fixture body did not render expected heading")
    if page.locator("vite-error-overlay, [data-nextjs-dialog-overlay]").count() > 0:
        raise RuntimeError("framework error overlay detected")


with sync_playwright() as pw:
    browser = pw.chromium.launch(headless=True)
    browser_errors = []

    desktop_context = browser.new_context(viewport={"width": 1440, "height": 900})
    desktop = desktop_context.new_page()
    desktop.on("console", lambda message: browser_errors.append(message.text) if message.type == "error" else None)
    desktop.on("pageerror", lambda error: browser_errors.append(str(error)))

    verify_page_health(desktop)
    open_tool(desktop, hydration_tool_selector)
    assert_visible_text(desktop, hydration_explanation)
    desktop.screenshot(path=hydration_expanded_screenshot, full_page=False)

    open_tool(desktop, coverage_tool_selector)
    assert_visible_text(desktop, coverage_explanation)
    desktop.screenshot(path=coverage_expanded_screenshot, full_page=False)
    desktop_context.close()

    mobile_context = browser.new_context(viewport={"width": 390, "height": 844})
    mobile = mobile_context.new_page()
    mobile.on("console", lambda message: browser_errors.append(message.text) if message.type == "error" else None)
    mobile.on("pageerror", lambda error: browser_errors.append(str(error)))

    verify_page_health(mobile)
    open_tool(mobile, hydration_tool_selector)
    assert_visible_text(mobile, hydration_explanation)
    open_tool(mobile, coverage_tool_selector)
    assert_visible_text(mobile, coverage_explanation)
    mobile.screenshot(path=mobile_expanded_screenshot, full_page=False)
    mobile_context.close()

    browser.close()

    if browser_errors:
        raise RuntimeError(f"browser console/page errors: {' | '.join(browser_errors)}")

print('pass\tfixture page identity, nonblank body, and no framework overlay')
print('pass\tdesktop hydration-failed row expands visible explanation')
print('pass\tdesktop coverage-gap row expands visible explanation')
print('pass\tmobile hydration-failed and coverage-gap rows expand visible explanations')
PY

env \
  FIXTURE_URL="${FIXTURE_URL}" \
  HYDRATION_EXPANDED_SCREENSHOT="${HYDRATION_EXPANDED_SCREENSHOT}" \
  COVERAGE_EXPANDED_SCREENSHOT="${COVERAGE_EXPANDED_SCREENSHOT}" \
  MOBILE_EXPANDED_SCREENSHOT="${MOBILE_EXPANDED_SCREENSHOT}" \
  "${PLAYWRIGHT_PYTHON_CMD[@]}" "${BROWSER_SCRIPT}"

printf 'keeper chat tool output failure contract DOM smoke passed\n'
printf 'fixture_url=%s\n' "${FIXTURE_URL}"
printf 'desktop_screenshot=%s\n' "${DESKTOP_SCREENSHOT}"
printf 'mobile_screenshot=%s\n' "${MOBILE_SCREENSHOT}"
printf 'hydration_failed_screenshot=%s\n' "${HYDRATION_SCREENSHOT}"
printf 'coverage_gap_screenshot=%s\n' "${COVERAGE_SCREENSHOT}"
printf 'hydration_expanded_screenshot=%s\n' "${HYDRATION_EXPANDED_SCREENSHOT}"
printf 'coverage_expanded_screenshot=%s\n' "${COVERAGE_EXPANDED_SCREENSHOT}"
printf 'mobile_expanded_screenshot=%s\n' "${MOBILE_EXPANDED_SCREENSHOT}"
