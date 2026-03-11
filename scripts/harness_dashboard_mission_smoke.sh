#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PORT="${PORT:-8947}"
HOST="${HOST:-127.0.0.1}"
BASE_URL="${BASE_URL:-http://${HOST}:${PORT}/dashboard/}"
MCP_URL="${MCP_URL:-http://${HOST}:${PORT}/mcp}"
BASE_PATH="${BASE_PATH:-$(mktemp -d "${TMPDIR:-/tmp}/masc-mission-fixture.XXXXXX")}"
SESSION_ID="${SESSION_ID:-ts-mission-fixture-001}"
KEEP_SERVER="${KEEP_SERVER:-0}"
KEEP_BASE_PATH="${KEEP_BASE_PATH:-0}"
PLAYWRIGHT_MODULE_PATH="${PLAYWRIGHT_MODULE_PATH:-}"
SERVER_LOG="${SERVER_LOG:-${BASE_PATH}/mission-smoke-server.log}"
SERVER_EXE="${SERVER_EXE:-$REPO_ROOT/_build/default/bin/main_eio.exe}"

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

wait_for_http() {
  local url="$1"
  local attempts="${2:-60}"
  local i=1
  while [ "$i" -le "$attempts" ]; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

if [ -x "$SERVER_EXE" ]; then
  nohup env \
    MASC_GUARDIAN_ENABLED=false \
    MASC_ORCHESTRATOR_ENABLED=false \
    MASC_LODGE_ENABLED=false \
    "$SERVER_EXE" --port "$PORT" --base-path "$BASE_PATH" >"$SERVER_LOG" 2>&1 &
else
  nohup env \
    MASC_GUARDIAN_ENABLED=false \
    MASC_ORCHESTRATOR_ENABLED=false \
    MASC_LODGE_ENABLED=false \
    "$REPO_ROOT/start-masc-mcp.sh" --port "$PORT" --base-path "$BASE_PATH" >"$SERVER_LOG" 2>&1 &
fi
SERVER_PID=$!

if ! wait_for_http "http://${HOST}:${PORT}/api/v1/dashboard/mission" 90; then
  echo "Dashboard mission endpoint did not become ready. See $SERVER_LOG" >&2
  exit 1
fi

BASE_PATH="$BASE_PATH" MCP_URL="$MCP_URL" SESSION_ID="$SESSION_ID" \
  "$SCRIPT_DIR/setup_dashboard_mission_fixture.sh"

BASE_URL="$BASE_URL" \
MCP_URL="$MCP_URL" \
SESSION_ID="$SESSION_ID" \
PLAYWRIGHT_MODULE_PATH="$PLAYWRIGHT_MODULE_PATH" \
node <<'NODE'
const { chromium } = require(process.env.PLAYWRIGHT_MODULE_PATH);

const base = process.env.BASE_URL;
const mcp = process.env.MCP_URL;
const sessionId = process.env.SESSION_ID;

async function wait(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function gotoHash(page, hash, expectText) {
  await page.goto(new URL(hash, base).toString(), { waitUntil: 'domcontentloaded', timeout: 20000 });
  if (!expectText) {
    await wait(1000);
    return;
  }
  await page.waitForFunction(
    expected => document.body && document.body.innerText.includes(expected),
    expectText,
    { timeout: 15000 },
  );
}

async function mcpCall(name, args) {
  const res = await fetch(mcp, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'application/json, text/event-stream',
    },
    body: JSON.stringify({
      jsonrpc: '2.0',
      id: Date.now() + Math.random(),
      method: 'tools/call',
      params: { name, arguments: args },
    }),
  });
  const text = await res.text();
  const dataLine = text.split('\n').find(line => line.startsWith('data: '));
  if (!dataLine) throw new Error(`No MCP data line for ${name}: ${text.slice(0, 400)}`);
  const payload = JSON.parse(dataLine.slice(6));
  if (payload.error) throw new Error(`${name} error: ${payload.error.message}`);
  return payload.result;
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const page = await context.newPage();
  const checks = [];

  await gotoHash(page, '#mission', 'Attention Queue');
  const body = await page.locator('body').innerText();
  checks.push({
    name: 'mission headings are ordered root-cause first',
    pass:
      body.indexOf('Attention Queue') !== -1
      && body.indexOf('Affected Sessions') !== -1
      && body.indexOf('Impacted Agents') !== -1
      && body.indexOf('Attention Queue') < body.indexOf('Affected Sessions')
      && body.indexOf('Affected Sessions') < body.indexOf('Impacted Agents'),
  });
  checks.push({
    name: 'attention card shows spawn failure fixture',
    pass: body.includes('session has 2 failed spawn event(s)') && body.includes('Recover failed worker coverage'),
  });
  checks.push({
    name: 'internal room signal is present',
    pass: body.includes('pending confirmation(s) are waiting for operator input'),
  });
  checks.push({
    name: 'raw IO placeholders are hidden by default',
    pass: !body.includes('표시 가능한 recent input 없음') && !body.includes('표시 가능한 recent output 없음'),
  });

  const attentionCard = page.locator('.mission-attention-card').first();
  await attentionCard.locator('.mission-card-select').click();
  await page.waitForFunction(id => {
    const text = document.body?.innerText ?? '';
    return text.includes(id) && text.includes('현재 drill-down');
  }, sessionId, { timeout: 15000 });
  const afterAttention = await page.locator('body').innerText();
  checks.push({
    name: 'attention click narrows sessions',
    pass: afterAttention.includes(sessionId) && afterAttention.includes('현재 drill-down'),
  });

  await attentionCard.locator('details summary').first().click();
  await page.waitForFunction(() => {
    const text = document.body?.innerText ?? '';
    return text.includes('evidence preview') || text.includes('llama-local-alpha');
  }, { timeout: 10000 });
  const afterDisclosure = await page.locator('body').innerText();
  checks.push({
    name: 'attention disclosure reveals linked evidence',
    pass: afterDisclosure.includes('llama-local-alpha') && afterDisclosure.includes('Connection refused on secondary runtime'),
  });

  const sessionCard = page.locator('.mission-crew-card').first();
  await sessionCard.locator('.mission-card-select').click();
  await page.waitForFunction(() => {
    const text = document.body?.innerText ?? '';
    return text.includes('llama-local-alpha') && text.includes('llama-local-beta');
  }, { timeout: 10000 });
  const afterSession = await page.locator('body').innerText();
  checks.push({
    name: 'session click narrows impacted agents',
    pass: afterSession.includes('llama-local-alpha') && afterSession.includes('llama-local-beta'),
  });

  const agentCard = page.locator('.mission-activity-card').first();
  await agentCard.locator('details summary').first().click();
  await page.waitForFunction(() => {
    const text = document.body?.innerText ?? '';
    return text.includes('최근 input') && text.includes('최근 output');
  }, { timeout: 10000 });
  const afterAgentDisclosure = await page.locator('body').innerText();
  checks.push({
    name: 'agent disclosure reveals IO details',
    pass: afterAgentDisclosure.includes('최근 input') && afterAgentDisclosure.includes('최근 output'),
  });

  await sessionCard.getByRole('button', { name: '세션 개입 열기' }).click();
  await page.waitForFunction(id => window.location.hash.includes('#intervene') && window.location.hash.includes(id), sessionId, { timeout: 10000 });
  checks.push({
    name: 'handoff to intervene preserves session target',
    pass: page.url().includes('#intervene') && page.url().includes(sessionId),
  });

  await gotoHash(page, '#mission', 'Attention Queue');
  const sessionCard2 = page.locator('.mission-crew-card').first();
  await sessionCard2.getByRole('button', { name: '세션 원인 보기' }).click();
  await page.waitForFunction(id => window.location.hash.includes('#command') && window.location.hash.includes(id), sessionId, { timeout: 10000 });
  checks.push({
    name: 'handoff to command preserves session target',
    pass: page.url().includes('#command') && page.url().includes(sessionId),
  });

  const missionJsonResult = await mcpCall('masc_operator_digest', { actor: 'mission-smoke', target_type: 'room' });
  checks.push({
    name: 'operator digest remains callable during smoke',
    pass: !!missionJsonResult,
  });

  const failed = checks.filter(check => !check.pass);
  console.log(JSON.stringify({ base, mcp, sessionId, checks }, null, 2));
  await browser.close();
  if (failed.length > 0) process.exit(1);
})().catch(err => {
  console.error(err);
  process.exit(1);
});
NODE
