#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

pick_free_port() {
  node <<'NODE'
const net = require('net');
const server = net.createServer();
server.listen(0, '127.0.0.1', () => {
  const address = server.address();
  console.log(address && typeof address === 'object' ? address.port : 8958);
  server.close();
});
NODE
}

log() {
  printf '[execution-smoke] %s\n' "$*" >&2
}

run_with_timeout() {
  local timeout_sec="$1"
  local label="$2"
  shift 2

  "$@" &
  local cmd_pid=$!

  (
    sleep "$timeout_sec"
    if kill -0 "$cmd_pid" >/dev/null 2>&1; then
      printf '[execution-smoke] timeout after %ss: %s\n' "$timeout_sec" "$label" >&2
      kill "$cmd_pid" >/dev/null 2>&1 || true
    fi
  ) &
  local watchdog_pid=$!

  local status=0
  wait "$cmd_pid" || status=$?
  kill "$watchdog_pid" >/dev/null 2>&1 || true
  wait "$watchdog_pid" 2>/dev/null || true
  return "$status"
}

PORT="${PORT:-$(pick_free_port)}"
HOST="${HOST:-127.0.0.1}"
BASE_URL="${BASE_URL:-http://${HOST}:${PORT}/dashboard/}"
BASE_PATH="${BASE_PATH:-$(mktemp -d "${TMPDIR:-/tmp}/masc-execution-fixture.XXXXXX")}"
KEEP_SERVER="${KEEP_SERVER:-0}"
KEEP_BASE_PATH="${KEEP_BASE_PATH:-0}"
PLAYWRIGHT_MODULE_PATH="${PLAYWRIGHT_MODULE_PATH:-}"
SERVER_LOG="${SERVER_LOG:-${BASE_PATH}/execution-smoke-server.log}"
SERVER_EXE="${SERVER_EXE:-$REPO_ROOT/_build/default/bin/main_eio.exe}"
SERVER_WAIT_SEC="${SERVER_WAIT_SEC:-45}"
BROWSER_TIMEOUT_SEC="${BROWSER_TIMEOUT_SEC:-120}"
BROWSER_SCRIPT="${BROWSER_SCRIPT:-${BASE_PATH}/execution-smoke.browser.js}"
FIXTURE_MODE="${FIXTURE_MODE:-execution_smoke}"

if [ -z "$PLAYWRIGHT_MODULE_PATH" ]; then
  PLAYWRIGHT_MODULE_PATH="$(node -p "try { require.resolve('playwright') } catch { '' }" 2>/dev/null || true)"
fi

if [ -z "$PLAYWRIGHT_MODULE_PATH" ]; then
  echo "Playwright module not found. Set PLAYWRIGHT_MODULE_PATH=/abs/path/to/playwright" >&2
  exit 1
fi

SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    if [ "$KEEP_SERVER" = "1" ]; then
      echo "Keeping server running: pid=$SERVER_PID log=$SERVER_LOG"
    else
      kill "$SERVER_PID" >/dev/null 2>&1 || true
      wait "$SERVER_PID" 2>/dev/null || true
    fi
  fi
  if [ "$KEEP_BASE_PATH" != "1" ]; then
    rm -rf "$BASE_PATH"
  else
    echo "Keeping fixture base path: $BASE_PATH"
  fi
}

trap cleanup EXIT

mkdir -p "$BASE_PATH"
log "base_path=$BASE_PATH port=$PORT fixture=$FIXTURE_MODE"

wait_for_http() {
  local url="$1"
  local attempts="${2:-45}"
  local i=1
  while [ "$i" -le "$attempts" ]; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      log "http ready: $url"
      return 0
    fi
    if [ $((i % 5)) -eq 0 ]; then
      log "waiting for http ($i/$attempts): $url"
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

log "starting server"
if [ -x "$SERVER_EXE" ]; then
  nohup env \
    MASC_ORCHESTRATOR_ENABLED=false \
    MASC_AUTONOMY_ENABLED=false \
    MASC_DASHBOARD_BRIEFING_MODELS=disabled \
    MASC_DASHBOARD_FIXTURE="$FIXTURE_MODE" \
    "$SERVER_EXE" --port "$PORT" --base-path "$BASE_PATH" >"$SERVER_LOG" 2>&1 &
else
  nohup env \
    MASC_ORCHESTRATOR_ENABLED=false \
    MASC_AUTONOMY_ENABLED=false \
    MASC_DASHBOARD_BRIEFING_MODELS=disabled \
    MASC_DASHBOARD_FIXTURE="$FIXTURE_MODE" \
    "$REPO_ROOT/start-masc.sh" --port "$PORT" --base-path "$BASE_PATH" >"$SERVER_LOG" 2>&1 &
fi
SERVER_PID=$!
log "server_pid=$SERVER_PID log=$SERVER_LOG"

if ! wait_for_http "http://${HOST}:${PORT}/health" "$SERVER_WAIT_SEC"; then
  echo "MASC server did not become healthy. See $SERVER_LOG" >&2
  exit 1
fi

if ! wait_for_http "http://${HOST}:${PORT}/api/v1/dashboard/execution" 15; then
  echo "Dashboard execution endpoint did not become ready. See $SERVER_LOG" >&2
  exit 1
fi

cat >"$BROWSER_SCRIPT" <<'NODE'
const { chromium } = require(process.env.PLAYWRIGHT_MODULE_PATH);

const base = process.env.BASE_URL;
const log = step => console.error(`[execution-smoke-browser] ${step}`);

async function wait(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function closeOverlay(page, testId) {
  const locator = page.locator(`[data-testid="${testId}"]`);
  if (await locator.count()) {
    await locator.click({ position: { x: 5, y: 5 } });
    await wait(300);
  }
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const page = await context.newPage();
  const checks = [];

  log('goto execution');
  await page.goto(new URL('#execution', base).toString(), { waitUntil: 'domcontentloaded', timeout: 20000 });
  await page.waitForSelector('[data-testid="execution.queue"]', { timeout: 15000 });

  checks.push({
    name: 'execution lanes render in fixture mode',
    pass:
      await page.locator('[data-testid="execution.queue"]').count() === 1
      && await page.locator('[data-testid="execution.session-briefs"]').count() === 1
      && await page.locator('[data-testid="execution.operation-briefs"]').count() === 1
      && await page.locator('[data-testid="execution.worker-support"]').count() === 1
      && await page.locator('[data-testid="execution.continuity"]').count() === 1
      && await page.locator('[data-testid="execution.offline-workers"]').count() === 1,
  });

  const body = await page.locator('body').innerText();
  checks.push({
    name: 'fixture content is visible',
    pass:
      body.includes('ts-execution-fixture-001')
      && body.includes('op-runtime-002')
      && body.includes('llama-local-alpha'),
  });

  checks.push({
    name: 'queue has cards',
    pass: await page.locator('[data-testid="execution.queue-card"]').count() >= 2,
  });

  checks.push({
    name: 'session lane has cards',
    pass: await page.locator('[data-testid="execution.session-card"]').count() >= 1,
  });

  checks.push({
    name: 'operation lane has cards',
    pass: await page.locator('[data-testid="execution.operation-card"]').count() >= 1,
  });

  checks.push({
    name: 'worker support lane has cards',
    pass: await page.locator('[data-testid="execution.worker-card"]').count() >= 1,
  });

  checks.push({
    name: 'offline worker lane has cards',
    pass: await page.locator('[data-testid="execution.offline-worker-card"]').count() >= 1,
  });

  await page.locator('[data-testid="execution.queue-card"]').first().click();
  checks.push({
    name: 'queue selection narrows sessions',
    pass: await page.locator('[data-testid="execution.session-card"]').count() === 1,
  });

  await page.locator('[data-testid="execution.handoff-intervene"]').first().click();
  await page.waitForFunction(() => window.location.hash.includes('#intervene') && window.location.hash.includes('source=execution'), { timeout: 10000 });
  checks.push({
    name: 'session handoff preserves execution source on intervene',
    pass: (await page.evaluate(() => window.location.hash)).includes('source=execution'),
  });

  await page.goto(new URL('#execution', base).toString(), { waitUntil: 'domcontentloaded', timeout: 20000 });
  await page.waitForSelector('[data-testid="execution.operation-card"]', { timeout: 10000 });
  await page.locator('[data-testid="execution.operation-card"]').first().click();
  await page.locator('[data-testid="execution.handoff-command"]').first().click();
  await page.waitForFunction(() => window.location.hash.includes('#command') && window.location.hash.includes('source=execution'), { timeout: 10000 });
  checks.push({
    name: 'operation handoff preserves execution source on command',
    pass: (await page.evaluate(() => window.location.hash)).includes('source=execution'),
  });

  await page.goto(new URL('#execution', base).toString(), { waitUntil: 'domcontentloaded', timeout: 20000 });
  await page.locator('[data-testid="execution.worker-card"]').first().click();
  await page.waitForSelector('[data-testid="agent-detail-overlay"]', { timeout: 10000 });
  checks.push({
    name: 'worker support row opens agent detail overlay',
    pass: (await page.locator('[data-testid="agent-detail-overlay"]').count()) === 1,
  });
  await closeOverlay(page, 'agent-detail-overlay');

  await page.locator('[data-testid="execution.continuity-card"]').first().click();
  await page.waitForSelector('[data-testid="keeper-detail-overlay"]', { timeout: 10000 });
  checks.push({
    name: 'continuity row opens keeper detail overlay',
    pass: (await page.locator('[data-testid="keeper-detail-overlay"]').count()) === 1,
  });
  await closeOverlay(page, 'keeper-detail-overlay');

  for (const check of checks) {
    console.log(`${check.pass ? 'pass' : 'fail'}\t${check.name}`);
  }

  const failed = checks.filter(check => !check.pass);
  await browser.close();
  if (failed.length > 0) {
    process.exitCode = 1;
  }
})().catch(err => {
  console.error(err);
  process.exitCode = 1;
});
NODE

log "running browser smoke"
if ! run_with_timeout "$BROWSER_TIMEOUT_SEC" "browser smoke" \
  env PLAYWRIGHT_MODULE_PATH="$PLAYWRIGHT_MODULE_PATH" BASE_URL="$BASE_URL" node "$BROWSER_SCRIPT"; then
  echo "Execution browser smoke failed. See $SERVER_LOG" >&2
  exit 1
fi
