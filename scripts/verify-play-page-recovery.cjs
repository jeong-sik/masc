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
  const messages = [
    { id:1, at:1, who:'keeper-a', speaker:'keeper', machine:'dos', text:'같이 보고 있어요.' },
    { id:2, at:2, who:'keeper-b', speaker:'keeper', machine:'msx', text:'다음 차례에 무엇을 할까요?' }
  ];
  const members = ['keeper-a', 'keeper-b', 'minsu'].map(name => ({ name, speaker:name === 'minsu' ? 'participant' : 'keeper', machine:'dos', seen_at:2 }));
  try {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
    page.on('pageerror', error => errors.push(error.message));
    await page.route('**/*', async route => {
      const request = route.request(), url = new URL(request.url());
      requests.push({ method: request.method(), path: url.pathname, query: url.search });
      if (url.pathname === '/play') return route.fulfill({ contentType: 'text/html', body: html });
      assert.equal(request.headers().authorization, 'Bearer fixture-token');
      let json;
      if (url.pathname === '/api/v1/play/room') {
        const body = request.postDataJSON();
        if (body.action === 'say') messages.push({ id:messages.length + 1, at:3, who:'minsu', speaker:'participant', machine:body.machine, text:body.text });
        json = { viewer:'minsu', messages, members, has_more:false, presence_seconds:60 };
      } else if (url.pathname === '/api/v1/play/seat') {
        seatReads += 1;
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
        connected = body.connected;
        if (!connected && !passed) released = true;
        json = { ok:true, connected };
      } else if (url.pathname === '/api/v1/dos/type') {
        assert.deepEqual(request.postDataJSON(), { text:'123' });
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
        if (url.searchParams.get('source_kind') === 'msx_capture') return route.fulfill({ json: {
          state:'changed', change_count:7, incarnation:'msx-fixture', activity:[],
          screen:{ format:'rgb8', width:1, height:1, rgb_base64:'AP8A' }
        } });
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
    await page.waitForFunction(() => document.getElementById('room-messages').textContent.includes('다음 차례'));
    await page.locator('#chat-text').fill('Keeper 둘과 함께 관전합니다.');
    await page.locator('#chat-send').click();
    await page.waitForFunction(() => document.getElementById('chat-text').value === '');
    assert.equal(messages.length, 3);
    const msxResponse = page.waitForResponse(response => {
      const url = new URL(response.url());
      return url.pathname === '/api/v1/lane-addons/live'
        && url.searchParams.get('source_kind') === 'msx_capture';
    });
    await page.locator('#machine-view').selectOption('msx');
    assert.equal((await msxResponse).status(), 200);
    await page.waitForFunction(() => [...document.getElementById('screen')
      .getContext('2d').getImageData(0, 0, 1, 1).data].join(',') === '0,255,0,255');
    assert.deepEqual(await pixel(), [0, 255, 0, 255]);
    await page.screenshot({ path:resolve(output, 'play-msx-mobile.png'), fullPage:true });
    await page.waitForFunction(() => document.getElementById('turn').textContent.includes('MSX'));
    assert.equal(await page.locator('#game-controls').isVisible(), false);
    await page.locator('#chat-text').fill('MSX도 같은 방입니다.');
    await page.locator('#chat-text').press('Enter');
    await page.waitForFunction(() => document.getElementById('chat-text').value === '');
    assert.equal(messages.at(-1).machine, 'msx');
    await page.locator('#machine-view').selectOption('dos');
    await page.waitForFunction(() => [...document.getElementById('screen')
      .getContext('2d').getImageData(0, 0, 1, 1).data].join(',') === '255,0,0,255');
    assert.deepEqual(await pixel(), [255, 0, 0, 255]);
    await page.waitForFunction(() => document.getElementById('turn').textContent.includes('내 차례'));
    await page.waitForFunction(() => document.getElementById('status').textContent === '');
    for (const width of [320, 390, 900, 1440]) {
      await page.setViewportSize({ width, height:844 });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), width);
    }
    await page.screenshot({ path:resolve(output, 'play-room-desktop.png'), fullPage:true });
    await page.setViewportSize({ width:390, height:844 });
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
    await page.locator('#chat-text').fill('다시 열기 전에 보관한 초안');
    assert.equal(await page.evaluate(() => JSON.parse(sessionStorage.getItem('masc.play.room.draft')).token), 'fixture-token');
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
    assert.equal(await page.locator('#chat-text').isDisabled(), true);
    assert.equal(await page.evaluate(() => sessionStorage.getItem('masc.play.room.draft')), null,
      'the bearer-bearing draft is removed before invitation storage');
    await page.evaluate(() => window.restoreStorageRemoval());
    await page.locator('#leave').click();
    await page.waitForFunction(() => sessionStorage.getItem('masc.play.invite') === null);
    assert.deepEqual(errors, []);
    assert.equal(padPressed, true);
    const receipt = { scope: 'Actual shipped page in Chromium with fixture API responses; no deployed binary or DOS emulator validation.',
      source_sha256: createHash('sha256').update(source).digest('hex'),
      browser_version: browser.version(), seat_reads: seatReads, frame_reads: frameReads,
      checks: ['seat recovers without machine activity', 'failed frame is fetched again',
        'several Keepers share public conversation', 'guest sends public message',
        'one viewport switches DOS and MSX without splitting conversation',
        'MSX live response renders green pixels before DOS red pixels return', 'room layout fits phone and desktop',
        'same-tab reload reconnects', 'pad click sends input', 'reopening focused selector discovers idle invite',
        'pass updates controller and disables input', 'eject clears pixels', 'disconnect removes tab credential',
        'atomic session departure precedes credential removal', 'departed same-link reopen explicitly reconnects',
        'partial DOS text retains unpressed suffix without replay', 'storage deletion failure retains credential and disables game input',
        'retry after storage deletion failure completes disconnect', 'HTTP origin supports mutation randomness', 'confirmed departure closes chat and clears draft before invitation removal'],
      requests, errors };
    await writeFile(resolve(output, 'play-browser.json'), JSON.stringify(receipt, null, 2) + '\n');
    console.log(JSON.stringify({ result: 'PASS', output, checks: receipt.checks }));
  } finally {
    await browser.close();
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
