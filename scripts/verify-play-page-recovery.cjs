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
  const note = source.match(/let agent_note =([\s\S]*?)let page_script =/)[1];
  const fragments = [...note.matchAll(/\{play\|([\s\S]*?)\|play\}/g)].map(match => match[1]);
  assert.equal(fragments.length, 3);
  const agentNote = fragments.join('/play/agent.md');
  const html = parts[0] + 'fixture-nonce' + parts[1] + agentNote + 'fixture-nonce' + parts[2];
  await mkdir(output, { recursive: true });
  const browser = await chromium.launch({ headless: true });
  const requests = [], errors = [];
  let seatReads = 0, frameReads = 0, passed = false, ejected = false, padPressed = false, invited = false, released = false, connected = true;
  let reconnectRefusals = 0, inputRefusal = null, activityRevision = 0;
  let stallProjectionAfterType = false, holdProjection = false, projectionStarted;
  const heldSeatReads = [];
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
        if (holdProjection) await new Promise(resolve => {
          heldSeatReads.push(resolve);
          projectionStarted();
        });
        if (seatReads <= 2) return route.fulfill({ status: 503, json: { error: 'fixture-unavailable' } });
        json = { name: 'minsu', connected, machine: !ejected, controller: ejected || released ? null : passed ? 'operator' : 'minsu',
          controller_recoverable: false,
          saves_name: ejected ? null : 'game', participants: (invited ? ['minsu', 'operator', 'newplayer'] : ['minsu', 'operator']).filter(name => connected || name !== 'minsu') };
      } else if (url.pathname === '/api/v1/play/pad') {
        if (request.method() === 'POST') {
          assert.deepEqual(request.postDataJSON(), { button: 'BTN_SOUTH', saves_name: 'game' });
          assert.equal(connected, true);
          padPressed = true;
          released = false;
        }
        json = request.method() === 'GET'
          ? { saves_name: 'game', buttons: [{ button: 'BTN_SOUTH', label: '결정', keys: ['return'] }] }
          : { ok: true };
      } else if (url.pathname === '/api/v1/play/session') {
        assert.equal(request.method(), 'POST');
        const body = request.postDataJSON();
        assert.deepEqual(Object.keys(body), ['connected']);
        assert.equal(typeof body.connected, 'boolean');
        if (body.connected && reconnectRefusals > 0) {
          reconnectRefusals -= 1;
          return route.fulfill({ status:503, json:{ ok:false, error:'participation unavailable' } });
        }
        connected = body.connected;
        if (!connected && !passed) released = true;
        json = { ok:true, connected };
      } else if (url.pathname === '/api/v1/dos/type') {
        assert.deepEqual(request.postDataJSON(), { text:'123' });
        if (inputRefusal !== null) {
          const status = inputRefusal;
          inputRefusal = null;
          return status === 413
            ? route.fulfill({ status, contentType:'text/plain', body:'Payload too large' })
            : route.fulfill({ status, json:{ error:'Too Many Requests', message:'Try later' } });
        }
        if (stallProjectionAfterType) holdProjection = true;
        json = { ok:true, data:{ keys_pressed:1 } };
      } else if (url.pathname === '/api/v1/dos/pass') {
        if (request.postDataJSON().to === 'operator') {
          assert.deepEqual(request.postDataJSON(), { to: 'operator' });
          passed = true;
        } else {
          assert.deepEqual(request.postDataJSON(), {});
          released = true;
        }
        json = { ok: true };
      } else if (url.pathname === '/api/v1/lane-addons/live') {
        frameReads += 1;
        const activity = [{ at: ejected ? 2 : 1 + activityRevision, who: 'operator',
          action: ejected ? 'eject' : passed ? 'pass operator' : 'pass minsu' }];
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
    await page.reload();
    await page.waitForFunction(() => document.getElementById('turn').textContent.includes('내 차례'));
    await page.waitForFunction(() => document.getElementById('screen').width === 1);
    assert.deepEqual(await pixel(), [255, 0, 0, 255]);
    await page.locator('#pad [data-button="BTN_SOUTH"]').click();
    await page.waitForFunction(() => document.getElementById('status').textContent === '');
    await page.locator('#text').fill('123');
    await page.locator('#send-text').click();
    await page.waitForFunction(() => document.getElementById('text').value === '23');
    assert.match(await page.locator('#status').textContent(), /일부만 입력/);
    assert.equal(requests.filter(request => request.path === '/api/v1/dos/type').length, 1);
    for (const status of [413, 429]) {
      inputRefusal = status;
      await page.locator('#text').fill('123');
      await page.locator('#send-text').click();
      await page.waitForFunction(() => sessionStorage.getItem('masc.play.pending') === null
        && !document.getElementById('send-text').disabled);
      assert.equal(inputRefusal, null, 'the fixture actually rejected the submitted body');
      assert.equal(await page.locator('#text').inputValue(), '123');
    }
    await page.locator('#pass-to').focus();
    invited = true;
    await page.locator('#pass-to').click();
    await page.waitForFunction(() => [...document.getElementById('pass-to').options].some(option => option.value === 'newplayer'));
    await page.keyboard.press('Escape');
    await page.locator('#pass-to').selectOption('operator');
    await page.locator('#pass').click();
    await page.waitForFunction(() => document.getElementById('turn').textContent === 'operator 님 차례예요');
    assert.equal(await page.locator('#send-text').isDisabled(), true);
    await page.screenshot({ path: resolve(output, 'play-passed-mobile.png'), fullPage: true });
    ejected = true;
    await page.waitForFunction(() => document.getElementById('status').textContent.includes('켜진 게임이 없어요'));
    assert.deepEqual(await pixel(), [0, 0, 0, 0]);
    await page.screenshot({ path: resolve(output, 'play-ejected-mobile.png'), fullPage: true });
    await page.locator('#leave').click();
    await page.waitForFunction(() => sessionStorage.getItem('masc.play.invite') === null);
    assert.equal(connected, false);
    ejected = false;
    passed = false;
    released = true;
    await page.goto('http://play.fixture/play#fixture-token');
    await page.waitForFunction(() => document.getElementById('turn').textContent.includes('조종권이 비어'));
    assert.equal(connected, true, 'reopening the same invitation explicitly rejoins');
    await page.locator('#pad [data-button="BTN_SOUTH"]').click();
    await page.waitForFunction(() => document.getElementById('turn').textContent.includes('내 차례'));
    await page.evaluate(() => {
      const remove = Storage.prototype.removeItem;
      window.restoreStorageRemoval = () => { Storage.prototype.removeItem = remove; };
      Storage.prototype.removeItem = function(key) {
        if (key === 'masc.play.invite') throw new Error('fixture deletion failure');
        return remove.call(this, key);
      };
    });
    await page.locator('#leave').click();
    await page.waitForFunction(() => document.getElementById('status').textContent.includes('지우지 못했어요'));
    assert.equal(connected, false);
    assert.equal(released, true, 'server departure precedes local removal');
    assert.equal(await page.evaluate(() => sessionStorage.getItem('masc.play.invite')), 'fixture-token');
    assert.equal(await page.locator('#send-text').isDisabled(), true);
    await page.reload();
    await page.waitForFunction(() => document.getElementById('turn').textContent.includes('조종 연결을 끊었어요'));
    assert.equal(connected, false, 'plain reload must preserve confirmed departure');
    await page.locator('#leave').click();
    await page.waitForFunction(() => sessionStorage.getItem('masc.play.invite') === null);
    reconnectRefusals = 2;
    await page.goto('http://play.fixture/play#fixture-token');
    await page.waitForFunction(() => document.getElementById('turn').textContent.includes('조종권이 비어'));
    assert.equal(reconnectRefusals, 0, 'explicit reconnect retries both transient refusals');
    assert.equal(connected, true);
    await page.locator('#leave').click();
    await page.waitForFunction(() => sessionStorage.getItem('masc.play.invite') === null);
    // Hold the clock before the recovery deadline: only an activity edge can
    // update this seat, so elapsed browser polling cannot make the check pass.
    passed = false; released = false; connected = true;
    await page.goto('http://play.fixture/play#fixture-token');
    await page.waitForFunction(() => document.getElementById('turn').textContent.includes('내 차례')
      && !document.getElementById('pad').hidden);
    await page.evaluate(() => {
      window.fixtureClock = performance.now.bind(performance);
      Object.defineProperty(performance, 'now', { configurable:true, value:() => 0 });
    });
    passed = true; activityRevision += 1;
    await page.waitForFunction(() => document.getElementById('turn').textContent === 'operator 님 차례예요');
    assert.equal(await page.locator('#send-text').isDisabled(), true);
    passed = false; activityRevision += 1;
    await page.waitForFunction(() => document.getElementById('turn').textContent.includes('내 차례'));
    assert.equal(await page.locator('#send-text').isDisabled(), false);
    await page.evaluate(() => { Object.defineProperty(performance, 'now', { configurable:true, value:window.fixtureClock }); });
    // The write has its receipt but its follow-up authority projection never
    // answers until after departure. Disconnect must only drain actual writes.
    const projectionRequested = new Promise(resolve => { projectionStarted = resolve; });
    stallProjectionAfterType = true;
    await page.locator('#text').fill('123');
    await page.locator('#send-text').click();
    await projectionRequested;
    await page.waitForFunction(() => document.getElementById('text').value === '23');
    assert.equal(await page.evaluate(() => sessionStorage.getItem('masc.play.pending')), null);
    await page.locator('#leave').click();
    await page.waitForFunction(() => sessionStorage.getItem('masc.play.invite') === null);
    assert.equal(connected, false, 'authoritative departure completes while its projection remains unanswered');
    holdProjection = false;
    for (const release of heldSeatReads) release();
    assert.deepEqual(errors, []);
    assert.equal(padPressed, true);
    const receipt = { scope: 'Actual shipped page in Chromium with fixture API responses; no deployed binary or DOS emulator validation.',
      source_sha256: createHash('sha256').update(source).digest('hex'),
      browser_version: browser.version(), seat_reads: seatReads, frame_reads: frameReads,
      checks: ['seat recovers without machine activity', 'failed frame is fetched again',
        'same-tab reload reconnects', 'pad click sends input', 'reopening focused selector discovers idle invite',
        'pass updates controller and disables input', 'eject clears pixels', 'disconnect removes tab credential',
        'atomic session departure precedes credential removal', 'departed same-link reopen explicitly reconnects',
        'partial DOS text retains unpressed suffix without replay', 'storage deletion failure retains credential and disables game input',
        'retry after storage deletion failure completes disconnect', 'HTTP origin supports mutation randomness',
        'confirmed departure survives plain reload after storage cleanup failure',
        'explicit invitation retries two transient reconnect refusals',
        'plain-text 413 and rate-limit 429 settle without losing the draft',
        'activity changes update ownership before the recovery deadline',
        'terminal write receipt and disconnect do not wait for a stalled seat projection'],
      requests, errors };
    await writeFile(resolve(output, 'play-browser.json'), JSON.stringify(receipt, null, 2) + '\n');
    console.log(JSON.stringify({ result: 'PASS', output, checks: receipt.checks }));
  } finally {
    await browser.close();
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
