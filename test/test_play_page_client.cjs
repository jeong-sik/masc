// Run the shipped page through its poll and input handlers. Failed reads
// must recover even when the machine remains at the same frame/activity.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');

const source = fs.readFileSync(path.join(__dirname,
  '../lib/server/server_routes_http_routes_play_page.ml'), 'utf8');
const script = source.match(/let page_script =\s*\{play\|">([\s\S]*?)<\/script>/)?.[1];
assert.ok(script, 'the script served by /play exists');

const activity = [{ at: 1, who: 'operator', action: 'pass minsu' }];
const seat = { name: 'minsu', machine: true, controller: 'minsu', saves_name: 'game',
  participants: ['minsu', 'operator'] };
const frame = { state: 'changed', change_count: 3, incarnation: 'machine-1',
  screen: { format: 'rgb8', width: 1, height: 1, rgb_base64: '/wAA' }, activity };
const layout = { saves_name: 'game', buttons: [
  { button: 'BTN_SOUTH', label: '결정', keys: ['return'] },
] };
const response = (json, status = 200) => ({ status, json: async () => json });

function fixture(reply) {
  const nodes = new Map();
  function element() {
    return { textContent: '', className: '', value: '', hidden: false,
      disabled: false, children: [], dataset: {}, handlers: {},
      addEventListener(name, fn) { this.handlers[name] = fn; },
      append(node) { this.children.push(node); },
      replaceChildren() { this.children = []; },
      get options() { return this.children; },
      focus() {},
    };
  }
  const get = id => {
    if (!nodes.has(id)) nodes.set(id, element());
    return nodes.get(id);
  };
  const padButton = element();
  padButton.dataset.button = 'BTN_SOUTH';
  get('pad').querySelectorAll = () => [padButton];
  get('pad').hidden = true;
  const rendered = [];
  let clears = 0;
  get('screen').width = 320;
  get('screen').height = 200;
  get('screen').getContext = () => ({
    createImageData: (w, h) => ({ data: new Uint8ClampedArray(w * h * 4) }),
    putImageData: image => rendered.push([...image.data]),
    clearRect: () => { clears += 1; },
  });
  const timers = [];
  const requests = [];
  const context = vm.createContext({
    document: {
      getElementById: get,
      createElement: element,
      querySelectorAll: selector => {
        if (selector === '#pad button[data-button]') return [padButton];
        if (selector === 'button, input, select') return [padButton, get('text'), get('send-text'), get('pass-to'), get('pass')];
        return [];
      },
    },
    location: { hash: '#fixture-token', pathname: '/play', search: '' },
    history: { replaceState() {} },
    window: { addEventListener() {} },
    navigator: { getGamepads: () => [] },
    requestAnimationFrame() {},
    atob,
    setTimeout: fn => timers.push(fn),
    fetch: async (url, init) => {
      const request = { url, method: init.method, body: init.body && JSON.parse(init.body) };
      requests.push(request);
      return reply(request);
    },
  });
  vm.runInContext(script, context);
  const settle = () => new Promise(resolve => setImmediate(resolve));
  return {
    get, padButton, rendered, requests, settle,
    get clears() { return clears; },
    async poll() {
      assert.equal(timers.length, 1, 'the page keeps one next poll');
      await timers.shift()();
      await settle();
    },
  };
}

for (const [name, refusal, control] of [
  ['changed program', { code: 'program_changed', error: '게임이 바뀌었어요. 패드를 다시 확인해 주세요.' }, 'pad'],
  ['denied handoff', { ok: false, message: '초대된 참여자에게만 넘길 수 있어요.' }, 'pass'],
]) {
  test(`a refused ${name} displays its explanation after refreshing the seat`, async () => {
    let refused = false;
    const page = fixture(({ url, method }) => {
      if (method === 'POST') { refused = true; return response(refusal, 409); }
      if (url === '/api/v1/play/seat') return response(seat);
      if (url === '/api/v1/play/pad') return response(layout);
      return response(frame);
    });
    await page.settle();
    if (control === 'pad') page.padButton.handlers.click();
    else {
      page.get('pass-to').value = 'operator';
      page.get('pass').handlers.click();
    }
    await page.settle();
    assert.equal(refused, true, 'the input reaches the server');
    assert.equal(page.get('status').textContent, refusal.message || refusal.error);
    assert.match(page.get('turn').textContent, /내 차례/);
  });
}

test('a failed seat read retries without a new move and restores playable controls', async () => {
  let seatReads = 0;
  const page = fixture(({ url, method }) => {
    if (url === '/api/v1/play/seat') return ++seatReads <= 2
      ? response({}, 503) : response(seat);
    if (url === '/api/v1/play/pad') return response(layout);
    if (method === 'POST') return response({ ok: true });
    return response(url.includes('since=') ? { ...frame, state: 'unchanged' } : frame);
  });
  await page.settle();
  assert.match(page.get('status').textContent, /자리/);
  await page.poll();
  assert.equal(seatReads, 3, 'retry the same activity after the seat recovers');
  assert.match(page.get('turn').textContent, /내 차례/);
  assert.equal(page.get('status').textContent, '');
  assert.equal(page.get('pad').hidden, false);
  page.padButton.handlers.click();
  await page.settle();
  assert.deepEqual(page.requests.find(r => r.method === 'POST'), {
    url: '/api/v1/play/pad', method: 'POST',
    body: { button: 'BTN_SOUTH', saves_name: 'game' },
  });
});

for (const [name, badScreen] of [
  ['wrong byte count', { ...frame.screen, width: 2 }],
  ['invalid base64', { ...frame.screen, rgb_base64: '!' }],
]) {
  test(`a frame rejected for ${name} is fetched again before acknowledging its mark`, async () => {
    let liveReads = 0;
    const page = fixture(({ url }) => {
      if (url === '/api/v1/play/seat') return response(seat);
      if (url === '/api/v1/play/pad') return response(layout);
      if (++liveReads === 1) return response({ ...frame, screen: badScreen });
      return response(url.includes('since=') ? { ...frame, state: 'unchanged' } : frame);
    });
    await page.settle();
    assert.equal(page.rendered.length, 0);
    await page.poll();
    assert.deepEqual(page.rendered, [[255, 0, 0, 255]], 'same frame is eventually drawn');
    assert.equal(page.get('status').textContent, '');
    await page.poll();
    const live = page.requests.filter(r => r.url.includes('/live?'));
    assert.equal(live[1].url.includes('since='), false, 'failed frame is not acknowledged');
    assert.equal(live[2].url.includes('since=3'), true, 'drawn frame is acknowledged');
  });
}

test('a failed seat request after an input retries while the activity feed is unchanged', async () => {
  let afterInput = false;
  let failSeat = false;
  const page = fixture(({ url, method }) => {
    if (method === 'POST') { afterInput = true; failSeat = true; return response({ ok: true }); }
    if (url === '/api/v1/play/seat') {
      if (failSeat) { failSeat = false; throw new Error('connection closed'); }
      return response(afterInput ? { ...seat, controller: 'operator' } : seat);
    }
    if (url === '/api/v1/play/pad') return response(layout);
    return response(url.includes('since=') ? { ...frame, state: 'unchanged' } : frame);
  });
  await page.settle();
  page.get('pass-to').value = 'operator';
  page.get('pass').handlers.click();
  await page.settle();
  assert.match(page.get('status').textContent, /자리 정보를 읽지 못했어요/);
  assert.doesNotMatch(page.get('status').textContent, /보내지 못했어요/);
  await page.poll();
  assert.equal(page.get('turn').textContent, 'operator 님 차례예요');
  assert.equal(page.get('status').textContent, '');
});

test('eject clears the last picture and the game pad', async () => {
  let ejected = false;
  const page = fixture(({ url }) => {
    if (url === '/api/v1/play/seat') return response(ejected
      ? { ...seat, machine: false, controller: null, saves_name: null } : seat);
    if (url === '/api/v1/play/pad') return response(layout);
    return response(ejected
      ? { state: 'no_machine', activity: [{ at: 2, who: 'operator', action: 'eject' }] }
      : frame);
  });
  await page.settle();
  assert.equal(page.rendered.length, 1);
  ejected = true;
  await page.poll();
  assert.equal(page.clears, 1);
  assert.equal(page.get('pad').hidden, true);
  assert.equal(page.padButton.disabled, true);
  assert.match(page.get('turn').textContent, /켜진 게임이 없어요/);
  assert.match(page.get('status').textContent, /켜진 게임이 없어요/);
});

test('no_machine hides the old pad while seat is unavailable and a loaded game restores controls', async () => {
  let ejected = false;
  const page = fixture(({ url }) => {
    if (url === '/api/v1/play/seat') return ejected ? response({}, 503) : response(seat);
    if (url === '/api/v1/play/pad') return response(layout);
    return response(ejected
      ? { state: 'no_machine', activity: [{ at: 2, who: 'operator', action: 'eject' }] }
      : frame);
  });
  await page.settle();
  ejected = true;
  await page.poll();
  assert.equal(page.clears, 1);
  assert.equal(page.get('pad').hidden, true, 'no_machine is sufficient to hide the stale game pad');
  assert.equal(page.padButton.disabled, true);
  assert.equal(page.get('pass').disabled, true);
  assert.match(page.get('turn').textContent, /켜진 게임이 없어요/);
  assert.match(page.get('status').textContent, /자리 정보를 읽지 못했어요/);
  ejected = false;
  await page.poll();
  assert.equal(page.get('pad').hidden, false);
  assert.equal(page.padButton.disabled, false);
  assert.equal(page.get('pass').disabled, false);
  assert.match(page.get('turn').textContent, /내 차례/);
  assert.equal(page.get('status').textContent, '');
});

test('a malformed frame does not prevent new activity from refreshing the controller', async () => {
  let corrupt = false;
  const page = fixture(({ url }) => {
    if (url === '/api/v1/play/seat') return response(corrupt ? { ...seat, controller: 'operator' } : seat);
    if (url === '/api/v1/play/pad') return response(layout);
    return response(corrupt ? { ...frame, change_count: 4,
      screen: { ...frame.screen, rgb_base64: '!' },
      activity: [{ at: 2, who: 'minsu', action: 'pass operator' }] } : frame);
  });
  await page.settle();
  corrupt = true;
  await page.poll();
  assert.equal(page.get('turn').textContent, 'operator 님 차례예요');
  assert.match(page.get('activity').children[0].textContent, /pass operator/);
  assert.match(page.get('status').textContent, /화면을 읽지 못했어요/);
  assert.equal(page.rendered.length, 1);
});

test('choosing a handoff discovers an invite added while the machine stays idle', async () => {
  let invited = false;
  const page = fixture(({ url, method }) => {
    if (url === '/api/v1/play/seat') return response(invited
      ? { ...seat, participants: [...seat.participants, 'newplayer'] } : seat);
    if (url === '/api/v1/play/pad') return response(layout);
    if (method === 'POST') return response({ ok: true });
    return response(url.includes('since=') ? { ...frame, state: 'unchanged' } : frame);
  });
  await page.settle();
  const select = page.get('pass-to');
  select.value = 'operator';
  invited = true;
  await page.poll();
  assert.equal(select.options.some(option => option.value === 'newplayer'), false);
  select.handlers.focus?.();
  await page.settle();
  assert.equal(select.value, 'operator', 'a still-valid selection survives refresh');
  assert.equal(select.options.some(option => option.value === 'newplayer'), true);
  select.value = 'newplayer';
  page.get('pass').handlers.click();
  await page.settle();
  assert.deepEqual(page.requests.find(request => request.method === 'POST'), {
    url: '/api/v1/dos/pass', method: 'POST', body: { to: 'newplayer' },
  });
});

test('revoked access keeps controls disabled and stops sending moves', async () => {
  let revoked = false;
  const page = fixture(({ url }) => {
    if (revoked) return response({}, 401);
    if (url === '/api/v1/play/seat') return response(seat);
    if (url === '/api/v1/play/pad') return response(layout);
    return response(frame);
  });
  await page.settle();
  assert.equal(page.padButton.disabled, false);
  revoked = true;
  await page.poll();
  assert.equal(page.padButton.disabled, true);
  assert.equal(page.get('pass').disabled, true);
  assert.match(page.get('turn').textContent, /초대가 끝났거나 회수됐어요/);
  page.padButton.handlers.click();
  page.get('pass-to').handlers.focus?.();
  await page.settle();
  assert.equal(page.requests.some(request => request.method === 'POST'), false);
});

test('an older seat response cannot overwrite a newer poll result', async () => {
  let defer = false;
  const pending = [];
  const page = fixture(({ url }) => {
    if (url === '/api/v1/play/seat') return defer
      ? new Promise(resolve => pending.push(resolve)) : response(seat);
    if (url === '/api/v1/play/pad') return response(layout);
    return response(url.includes('since=') ? { ...frame, state: 'unchanged' } : frame);
  });
  await page.settle();
  defer = true;
  page.get('pass-to').handlers.focus?.();
  const poll = page.poll();
  await page.settle();
  assert.equal(pending.length, 2);
  pending[1](response({ ...seat, controller: 'operator' }));
  await poll;
  pending[0](response({ ...seat, machine: false, controller: null, saves_name: null }));
  await page.settle();
  assert.equal(page.get('turn').textContent, 'operator 님 차례예요');
  assert.equal(page.get('pass').disabled, false);
  defer = false;
  await page.poll();
  assert.equal(page.get('turn').textContent, 'operator 님 차례예요');
});

test('reopening a focused handoff selector refreshes new invites once per opening', async () => {
  let invited = false;
  let seatReads = 0;
  const page = fixture(({ url }) => {
    if (url === '/api/v1/play/seat') {
      seatReads += 1;
      return response(invited ? { ...seat, participants: [...seat.participants, 'newplayer'] } : seat);
    }
    if (url === '/api/v1/play/pad') return response(layout);
    return response(frame);
  });
  await page.settle();
  const select = page.get('pass-to');
  const before = seatReads;
  select.handlers.pointerdown?.();
  select.handlers.focus?.();
  await page.settle();
  assert.equal(seatReads, before + 1, 'pointer plus focus share a read');
  invited = true;
  select.handlers.pointerdown?.();
  await page.settle();
  assert.equal(select.options.some(option => option.value === 'newplayer'), true);
  const reopened = seatReads;
  select.handlers.keydown?.({ key: 'ArrowDown' });
  await page.settle();
  assert.equal(seatReads, reopened + 1, 'keyboard reopening refreshes too');
});


test('an unreadable controller disables moves and recovers without new machine activity', async () => {
  let unreadable = false;
  const page = fixture(({ url, method }) => {
    if (url === '/api/v1/play/seat') return response(unreadable
      ? { ...seat, controller: null, saves_name: null, controller_error: 'DOS save unreadable' }
      : { ...seat, controller: 'operator' });
    if (url === '/api/v1/play/pad') return response(layout);
    if (method === 'POST') return response({ ok: true });
    return response(url.includes('since=') ? { ...frame, state: 'unchanged' } : frame);
  });
  await page.settle();
  assert.equal(page.get('turn').textContent, 'operator 님 차례예요');
  unreadable = true;
  page.get('pass-to').handlers.focus();
  await page.settle();
  assert.match(page.get('turn').textContent, /조종권을 확인하지 못했어요/);
  assert.doesNotMatch(page.get('turn').textContent, /비어 있어요/);
  assert.equal(page.get('status').textContent, 'DOS save unreadable');
  assert.equal(page.padButton.disabled, true);
  assert.equal(page.get('pass').disabled, true);
  page.padButton.handlers.click();
  await page.settle();
  assert.equal(page.requests.some(request => request.method === 'POST'), false);
  await page.poll();
  assert.equal(page.get('pass').disabled, true, 'an unchanged frame cannot clear the read failure');
  unreadable = false;
  await page.poll();
  assert.equal(page.get('turn').textContent, 'operator 님 차례예요');
  assert.equal(page.get('status').textContent, '');
  assert.equal(page.get('pass').disabled, false);
  assert.equal(page.padButton.disabled, false);
});
