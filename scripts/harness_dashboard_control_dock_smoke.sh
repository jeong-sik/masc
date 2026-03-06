#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8935/dashboard/}"
PLAYWRIGHT_MODULE_PATH="${PLAYWRIGHT_MODULE_PATH:-}"

if [ -z "$PLAYWRIGHT_MODULE_PATH" ]; then
  PLAYWRIGHT_MODULE_PATH="$(node -p "try { require.resolve('playwright') } catch { '' }" 2>/dev/null || true)"
fi

if [ -z "$PLAYWRIGHT_MODULE_PATH" ]; then
  echo "Playwright module not found. Set PLAYWRIGHT_MODULE_PATH=/abs/path/to/playwright" >&2
  exit 1
fi

BASE_URL="$BASE_URL" \
PLAYWRIGHT_MODULE_PATH="$PLAYWRIGHT_MODULE_PATH" \
node <<'NODE'
const { chromium } = require(process.env.PLAYWRIGHT_MODULE_PATH);

const base = process.env.BASE_URL;

async function wait(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function waitForBodyText(page, expected, timeout = 15000) {
  await page.waitForFunction(
    text => document.body && document.body.innerText.includes(text),
    expected,
    { timeout },
  );
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  const checks = [];

  await page.goto(new URL('#overview', base).toString(), {
    waitUntil: 'domcontentloaded',
    timeout: 20000,
  });

  await waitForBodyText(page, 'Control Dock');
  await waitForBodyText(page, 'Room Broadcast');
  await waitForBodyText(page, 'Keeper Direct Message');
  await waitForBodyText(page, 'Lodge Status');

  const bodyText = await page.locator('body').innerText();
  checks.push({
    name: 'control dock sections visible',
    pass:
      bodyText.includes('Room Broadcast')
      && bodyText.includes('Keeper Direct Message')
      && bodyText.includes('Lodge Status')
      && bodyText.includes('Quick Task'),
  });

  checks.push({
    name: 'lodge explanatory copy visible',
    pass: /Quiet hours|Lodge ticks every|Lodge runtime status is unavailable|Lodge automation is disabled/i.test(bodyText),
  });

  const pokeButton = page.getByRole('button', { name: /Poke Now/i });
  await pokeButton.click();
  await page.waitForFunction(() => {
    const text = document.body?.innerText ?? '';
    return /\b\d+\s+checked\b/i.test(text) || /disabled|quiet hours bypassed/i.test(text);
  }, { timeout: 20000 });
  const afterPoke = await page.locator('body').innerText();
  checks.push({
    name: 'poke now shows result summary',
    pass: /\b\d+\s+checked\b/i.test(afterPoke) || /disabled/i.test(afterPoke),
  });

  const keeperSelect = page.locator('#dock-keeper');
  const keeperPrompt = page.locator('textarea').nth(1);
  const directButton = page.getByRole('button', { name: /Send Direct Message/i });
  const options = await keeperSelect.locator('option').allTextContents();
  const keeperAvailable = options.some(text => text && !/No keepers available/i.test(text));

  if (keeperAvailable) {
    await keeperSelect.selectOption({ index: 0 });
    await keeperPrompt.fill(`control dock smoke ${Date.now()}`);
    await directButton.click();
    await page.waitForFunction(() => {
      const text = document.body?.innerText ?? '';
      return text.includes('Prompt') && (text.includes('Reply') || text.includes('Error'));
    }, { timeout: 30000 });
    const afterDirect = await page.locator('body').innerText();
    checks.push({
      name: 'keeper direct message writes transcript',
      pass: afterDirect.includes('Prompt') && (afterDirect.includes('Reply') || afterDirect.includes('Error')),
    });
  } else {
    checks.push({
      name: 'keeper empty state visible',
      pass: bodyText.includes('No keepers available') || bodyText.includes('No direct keeper response yet.'),
    });
  }

  console.log(JSON.stringify({ base, checks }, null, 2));
  await browser.close();

  const failed = checks.filter(check => !check.pass);
  if (failed.length > 0) {
    process.exit(1);
  }
})().catch(err => {
  console.error(err);
  process.exit(1);
});
NODE
