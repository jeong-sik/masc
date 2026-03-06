#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8935/dashboard/}"
MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
PLAYWRIGHT_MODULE_PATH="${PLAYWRIGHT_MODULE_PATH:-}"

if [ -z "$PLAYWRIGHT_MODULE_PATH" ]; then
  PLAYWRIGHT_MODULE_PATH="$(node -p "try { require.resolve('playwright') } catch { '' }" 2>/dev/null || true)"
fi

if [ -z "$PLAYWRIGHT_MODULE_PATH" ]; then
  echo "Playwright module not found. Set PLAYWRIGHT_MODULE_PATH=/abs/path/to/playwright" >&2
  exit 1
fi

BASE_URL="$BASE_URL" \
MCP_URL="$MCP_URL" \
PLAYWRIGHT_MODULE_PATH="$PLAYWRIGHT_MODULE_PATH" \
node <<'NODE'
const { chromium } = require(process.env.PLAYWRIGHT_MODULE_PATH);

const base = process.env.BASE_URL;
const mcp = process.env.MCP_URL;

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
      id: Date.now(),
      method: 'tools/call',
      params: { name, arguments: args },
    }),
  });

  const text = await res.text();
  const dataLine = text.split('\n').find(line => line.startsWith('data: '));
  if (!dataLine) {
    throw new Error(`No MCP data line for ${name}: ${text.slice(0, 400)}`);
  }

  const payload = JSON.parse(dataLine.slice(6));
  if (payload.error) {
    throw new Error(`${name} error: ${payload.error.message}`);
  }

  return payload.result;
}

function extractJsonObject(text) {
  const idx = text.indexOf('{');
  if (idx === -1) return null;
  try {
    return JSON.parse(text.slice(idx));
  } catch {
    return null;
  }
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const page = await context.newPage();
  const checks = [];

  const unique = `dashboard-smoke-${Date.now()}`;

  await gotoHash(page, '#overview', 'Overview');
  checks.push({
    name: 'overview loads',
    pass: (await page.locator('body').innerText()).includes('Overview'),
  });

  await gotoHash(page, '#board', 'Board');
  const toggle = page.getByRole('button', { name: /hide auto reports/i });
  if (await toggle.count()) {
    await toggle.click().catch(() => {});
  }
  await wait(500);

  const postResult = await mcpCall('masc_board_post', {
    author: 'dashboard-smoke-bot',
    content: unique,
    hearth: 'dashboard',
    visibility: 'internal',
    ttl_hours: 24,
  });
  const postText = postResult.content?.[0]?.text || postResult.resultEnvelope?.summary || '';
  const postJson = extractJsonObject(postText) || {};
  const postId = postJson.id || 'unknown';

  await page.waitForFunction(expected => document.body.innerText.includes(expected), unique, { timeout: 10000 });
  const boardBody = await page.locator('body').innerText();
  checks.push({
    name: 'board auto-refreshes with author and post preview',
    pass: boardBody.includes('dashboard-smoke-bot') && boardBody.includes(unique),
    postId,
  });

  const commentText = `${unique}-comment`;
  const commentResult = await mcpCall('masc_board_comment', {
    author: 'dashboard-smoke-bot',
    post_id: postId,
    content: commentText,
  });

  await gotoHash(page, '#activity', 'Activity');
  await page.waitForFunction(expected => document.body.innerText.includes(expected), unique, { timeout: 10000 });
  await wait(1500);
  const activityBody = await page.locator('body').innerText();
  checks.push({
    name: 'activity shows labeled board post preview',
    pass: activityBody.includes('dashboard-smoke-bot') && activityBody.includes(`Post: ${unique}`),
  });
  checks.push({
    name: 'activity shows labeled board comment preview',
    pass: !commentResult.isError && activityBody.includes(`Comment: ${commentText}`),
  });

  await gotoHash(page, '#board/post/p-7691ae3d1d7cc04bbef1f0e31aea7963', 'COMMENTS');
  const detailBody = await page.locator('body').innerText();
  checks.push({
    name: 'filtered system post detail fallback works',
    pass: !detailBody.includes('Post not found') && /COMMENTS \(/i.test(detailBody),
  });

  const failed = checks.filter(check => !check.pass);
  console.log(JSON.stringify({ base, mcp, checks }, null, 2));
  await browser.close();

  if (failed.length > 0) {
    process.exit(1);
  }
})().catch(err => {
  console.error(err);
  process.exit(1);
});
NODE
