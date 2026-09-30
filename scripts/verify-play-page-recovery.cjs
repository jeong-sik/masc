// Browser proof for the shipped /play HTML against controlled API failures.
// No server binary or emulator is run; this measures client recovery only.
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { readFile, mkdir, writeFile } = require('node:fs/promises');
const { createRequire } = require('node:module');
const { resolve } = require('node:path');

async function main() {
  const [rootArg, outputArg, packageArg] = process.argv.slice(2);
  assert.ok(rootArg && outputArg, 'Usage: SOURCE_ROOT OUTPUT_DIR [PLAYWRIGHT_PACKAGE_JSON]');
  const root = resolve(rootArg), output = resolve(outputArg);
  const requirePlaywright = createRequire(resolve(packageArg || `${root}/dashboard/package.json`));
  const { chromium } = requirePlaywright('playwright');
  const source = await readFile(resolve(root, 'lib/server/server_routes_http_routes_play_page.ml'), 'utf8');
  const parts = ['head', 'style', 'script'].map(name => {
    const found = source.match(new RegExp(`let page_${name} =\\s*\\{play\\|([\\s\\S]*?)\\|play\\}`));
    assert.ok(found, `page_${name}`);
    return found[1];
  });
  const html = parts.join('fixture-nonce');
  await mkdir(output, { recursive: true });
  const browser = await chromium.launch({ headless: true });
  const requests = [], errors = [];
  let seatReads = 0, frameReads = 0, passed = false, ejected = false, padPressed = false, invited = false;
  try {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
    page.on('pageerror', error => errors.push(error.message));
    await page.route('**/*', async route => {
      const request = route.request(), url = new URL(request.url());
      requests.push({ method: request.method(), path: url.pathname, query: url.search });
      if (url.pathname === '/play') return route.fulfill({ contentType: 'text/html', body: html });
      assert.equal(request.headers().authorization, 'Bearer fixture-token');
      let json;
      if (url.pathname === '/api/v1/play/seat') {
        seatReads += 1;
        if (seatReads <= 2) return route.fulfill({ status: 503, json: { error: 'fixture-unavailable' } });
        json = { name: 'minsu', machine: !ejected, controller: ejected ? null : passed ? 'operator' : 'minsu',
          saves_name: ejected ? null : 'game', participants: invited ? ['minsu', 'operator', 'newplayer'] : ['minsu', 'operator'] };
      } else if (url.pathname === '/api/v1/play/pad') {
        if (request.method() === 'POST') {
          assert.deepEqual(request.postDataJSON(), { button: 'BTN_SOUTH', saves_name: 'game' });
          padPressed = true;
        }
        json = request.method() === 'GET'
          ? { saves_name: 'game', buttons: [{ button: 'BTN_SOUTH', label: '결정', keys: ['return'] }] }
          : { ok: true };
      } else if (url.pathname === '/api/v1/dos/pass') {
        assert.deepEqual(request.postDataJSON(), { to: 'operator' });
        passed = true;
        json = { ok: true };
      } else if (url.pathname === '/api/v1/lane-addons/live') {
        frameReads += 1;
        const activity = [{ at: ejected ? 2 : 1, who: 'operator', action: ejected ? 'eject' : 'pass minsu' }];
        json = ejected ? { state: 'no_machine', activity }
          : url.searchParams.has('since')
            ? { state: 'unchanged', change_count: 3, incarnation: 'machine-1', activity }
            : { state: 'changed', change_count: 3, incarnation: 'machine-1', activity,
              screen: { format: 'rgb8', width: frameReads === 1 ? 2 : 1, height: 1, rgb_base64: '/wAA' } };
      } else {
        throw new Error(`unexpected request ${request.method()} ${url.pathname}`);
      }
      await route.fulfill({ json });
    });
    await page.goto('http://play.fixture/play#fixture-token');
    await page.waitForFunction(() => document.getElementById('turn').textContent.includes('내 차례'));
    await page.waitForFunction(() => document.getElementById('status').textContent === '');
    const pixel = () => page.evaluate(() => [...document.getElementById('screen')
      .getContext('2d').getImageData(0, 0, 1, 1).data]);
    assert.deepEqual(await pixel(), [255, 0, 0, 255]);
    assert.ok(seatReads >= 3);
    assert.equal(new URL(page.url()).hash, '');
    await page.screenshot({ path: resolve(output, 'play-recovered-mobile.png'), fullPage: true });
    await page.locator('#pad [data-button="BTN_SOUTH"]').click();
    await page.waitForFunction(() => document.getElementById('status').textContent === '');
    await page.locator('#pass-to').focus();
    invited = true;
    await page.locator('#pass-to').click();
    await page.waitForFunction(() => [...document.getElementById('pass-to').options].some(option => option.value === 'newplayer'));
    await page.keyboard.press('Escape');
    await page.locator('#pass-to').selectOption('operator');
    await page.locator('#pass').click();
    await page.waitForFunction(() => document.getElementById('turn').textContent === 'operator 님 차례예요');
    await page.screenshot({ path: resolve(output, 'play-passed-mobile.png'), fullPage: true });
    ejected = true;
    await page.waitForFunction(() => document.getElementById('status').textContent.includes('켜진 게임이 없어요'));
    assert.deepEqual(await pixel(), [0, 0, 0, 0]);
    await page.screenshot({ path: resolve(output, 'play-ejected-mobile.png'), fullPage: true });
    assert.deepEqual(errors, []);
    assert.equal(padPressed, true);
    const receipt = { scope: 'Actual shipped page in Chromium with fixture API responses; no deployed binary or DOS emulator validation.',
      source_sha256: createHash('sha256').update(source).digest('hex'),
      browser_version: browser.version(), seat_reads: seatReads, frame_reads: frameReads,
      checks: ['seat recovers without machine activity', 'failed frame is fetched again',
        'pad click sends input', 'reopening focused selector discovers idle invite', 'pass updates controller', 'eject clears pixels'],
      requests, errors };
    await writeFile(resolve(output, 'play-browser.json'), JSON.stringify(receipt, null, 2) + '\n');
    console.log(JSON.stringify({ result: 'PASS', output, checks: receipt.checks }));
  } finally {
    await browser.close();
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
