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
const seat = { name: 'minsu', connected:true, machine: true, controller: 'minsu', controller_recoverable: false, saves_name: 'game',
  participants: ['minsu', 'operator'] };
const frame = { state: 'changed', change_count: 3, incarnation: 'machine-1',
  screen: { format: 'rgb8', width: 1, height: 1, rgb_base64: '/wAA' }, activity };
const layout = { saves_name: 'game', buttons: [
  { button: 'BTN_SOUTH', label: '결정', keys: ['return'] },
] };
const response = (json, status = 200) => ({ status, json: async () => json });

function fixture(reply, { storage = new Map(), hash = '#fixture-token',
  sessionReply = ({ body }) => response({ ok:true, connected:body.connected }) } = {}) {
  const nodes = new Map();
  function element() {
    let disabled = false;
    return { textContent: '', className: '', value: '', hidden: false,
      disabledChanges: [],
      get disabled() { return disabled; },
      set disabled(value) { disabled = value; this.disabledChanges.push(value); },
      children: [], dataset: {}, handlers: {},
      addEventListener(name, fn) { this.handlers[name] = fn; },
      append(node) { this.children.push(node); },
      replaceChildren() { this.children = []; },
      get options() { return this.children; },
      focus() {},
    };
  }
  const get = id => {
    if (!nodes.has(id)) { const node = element(); node.id = id; nodes.set(id, node); }
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
  const windowHandlers = new Map();
  let reloads = 0;
  let now = 0;
  const location = { hash, pathname: '/play', search: '', reload() { reloads += 1; } };
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
    location,
    sessionStorage: { getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key) },
    history: { replaceState(_state, _title, url) { const at = url.indexOf('#'); location.hash = at < 0 ? '' : url.slice(at); } },
    window: { addEventListener(name, handler) { windowHandlers.set(name, handler); } },
    navigator: { getGamepads: () => [] },
    requestAnimationFrame() {},
    atob,
    crypto: { getRandomValues: values => require('node:crypto').webcrypto.getRandomValues(values) },
    TextEncoder,
    AbortController,
    performance: { now: () => now },
    setTimeout: (callback, delay) => { timers.push({ callback, delay }); },
    fetch: async (url, init) => {
      const request = { url, authorization: init.headers.Authorization, method: init.method, body: init.body && JSON.parse(init.body) };
      if (init.signal !== undefined) Object.defineProperty(request, 'signal', { value: init.signal });
      requests.push(request);
      if (url === '/api/v1/play/session') return sessionReply(request);
      return reply(request);
    },
  });
  vm.runInContext(script, context);
  const settle = () => new Promise(resolve => setImmediate(resolve));
  return {
    get, padButton, rendered, requests, settle,
    // Frame polls only: seat authority keeps its own independent timer.
    get timerCount() { return timers.filter(timer => timer.delay === 300).length; },
    get reloads() { return reloads; },
    get hash() { return location.hash; },
    navigateFragment(hash) { context.location.hash = hash; windowHandlers.get('hashchange')?.(); },
    restoreFromCache() { windowHandlers.get('pageshow')?.({ persisted: true }); },
    get clears() { return clears; },
    async poll(elapsed = 5000) {
      now += elapsed;
      const pending = timers.filter(timer => timer.delay === 300);
      assert.equal(pending.length, 1, 'the page keeps one next poll');
      timers.splice(timers.indexOf(pending[0]), 1);
      await pending[0].callback();
      await settle();
    },
    async seatTick() {
      const pending = timers.filter(timer => timer.delay === 5000);
      assert.equal(pending.length, 1, 'authority keeps one independent timer');
      timers.splice(timers.indexOf(pending[0]), 1);
      now += pending[0].delay;
      await pending[0].callback();
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
  assert.equal(seatReads, 2, 'the first observed activity immediately retries the initial failed read');
  assert.equal(page.padButton.disabled, true);
  await page.poll(300);
  assert.equal(seatReads, 2, 'unchanged activity does not bypass the recovery cadence');
  await page.poll(4700);
  assert.equal(seatReads, 3, 'retry the same activity after the seat recovers');
  assert.match(page.get('turn').textContent, /내 차례/);
  assert.equal(page.get('status').textContent, '');
  assert.equal(page.get('pad').hidden, false);
  page.padButton.handlers.click();
  await page.settle();
  assert.deepEqual(page.requests.find(r => r.method === 'POST'), {
    url: '/api/v1/play/pad', authorization: 'Bearer fixture-token', method: 'POST',
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
  await page.poll(300);
  assert.equal(select.options.some(option => option.value === 'newplayer'), false);
  select.handlers.focus?.();
  await page.settle();
  assert.equal(select.value, 'operator', 'a still-valid selection survives refresh');
  assert.equal(select.options.some(option => option.value === 'newplayer'), true);
  select.value = 'newplayer';
  page.get('pass').handlers.click();
  await page.settle();
  assert.deepEqual(page.requests.find(request => request.method === 'POST'), {
    url: '/api/v1/dos/pass', authorization: 'Bearer fixture-token', method: 'POST', body: { to: 'newplayer' },
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
  let currentSeat = seat;
  const pending = [];
  const page = fixture(({ url }) => {
    if (url === '/api/v1/play/seat') return defer
      ? new Promise(resolve => pending.push(resolve)) : response(currentSeat);
    if (url === '/api/v1/play/pad') return response(layout);
    return response(url.includes('since=') ? { ...frame, state: 'unchanged' } : frame);
  });
  await page.settle();
  defer = true;
  page.get('pass-to').handlers.focus?.();
  const poll = page.poll();
  await page.settle();
  assert.equal(pending.length, 2);
  currentSeat = { ...seat, controller: 'operator' };
  pending[1](response(currentSeat));
  await poll;
  pending[0](response({ ...seat, machine: false, controller: null, saves_name: null }));
  await page.settle();
  assert.equal(page.get('turn').textContent, 'operator 님 차례예요');
  assert.equal(page.get('pass').disabled, true, 'another player holds the controller');
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
  assert.equal(page.get('pass').disabled, true, 'another player holds the controller');
  assert.equal(page.padButton.disabled, true, 'another player holds the controller');
});

for (const [name, fail] of [
  ['HTTP failure', () => response({}, 502)],
  ['malformed seat', () => response({ ...seat, machine: 'true' })],
  ['missing controller departure authority', () => response({ ...seat, controller_recoverable: undefined })],
  ['invalid JSON', () => ({ status: 200, json: async () => { throw new SyntaxError('invalid JSON'); } })],
  ['transport failure', () => { throw new Error('connection closed'); }],
]) {
  test(`a ${name} after a valid seat prevents input until ownership is readable again`, async () => {
    let unreadable = false;
    const page = fixture(({ url, method }) => {
      if (url === '/api/v1/play/seat') return unreadable ? fail() : response(seat);
      if (url === '/api/v1/play/pad') return response(layout);
      if (method === 'POST') return response({ ok: true });
      return response(url.includes('since=') ? { ...frame, state: 'unchanged' } : frame);
    });
    await page.settle();
    assert.equal(page.padButton.disabled, false);
    unreadable = true;
    page.get('pass-to').handlers.focus();
    await page.settle();
    assert.match(page.get('turn').textContent, /조종권을 확인하지 못했어요/);
    assert.equal(page.padButton.disabled, true);
    assert.equal(page.get('pass').disabled, true);
    page.padButton.handlers.click();
    await page.settle();
    assert.equal(page.requests.some(request => request.method === 'POST'), false);
    await page.poll();
    assert.equal(page.padButton.disabled, true, 'the unchanged frame cannot restore unread ownership');
    unreadable = false;
    await page.poll();
    assert.match(page.get('turn').textContent, /내 차례/);
    assert.equal(page.padButton.disabled, false);
    assert.equal(page.get('status').textContent, '');
    page.padButton.handlers.click();
    await page.settle();
    assert.equal(page.requests.filter(request => request.method === 'POST').length, 1);
  });
}

const normalReply = ({ url, method }) => response(method === 'POST' ? { ok: true }
  : url === '/api/v1/play/seat' ? seat
  : url === '/api/v1/play/pad' ? layout : frame);

test('reloading reconnects the same tab and disconnect clears its credential', async () => {
  const storage = new Map();
  const first = fixture(normalReply, { storage });
  await first.settle();
  const reloaded = fixture(normalReply, { storage, hash: '' });
  await reloaded.settle();
  assert.match(reloaded.get('turn').textContent, /내 차례/);
  assert.ok(reloaded.requests.every(request => request.authorization === 'Bearer fixture-token'));
  await reloaded.get('leave').handlers.click();
  const left = fixture(normalReply, { storage, hash: '' });
  await left.settle();
  assert.equal(left.requests.length, 0);
  assert.equal(storage.size, 0);
});

test('a revoked invitation clears the tab credential and a new link replaces it', async () => {
  const storage = new Map([['masc.play.invite', 'old-token']]);
  const revoked = fixture(() => response({}, 401), { storage, hash: '' });
  await revoked.settle();
  assert.equal(storage.size, 0);
  const fresh = fixture(normalReply, { storage, hash: '#new-token' });
  await fresh.settle();
  assert.ok(fresh.requests.every(request => request.authorization === 'Bearer new-token'));
});

test('another controller permits observation but no keyboard, pad or handoff mutation', async () => {
  const page = fixture(request => request.url === '/api/v1/play/seat'
    ? response({ ...seat, controller: 'operator' }) : normalReply(request));
  await page.settle();
  page.padButton.handlers.click();
  page.get('pass').handlers.click();
  page.get('text').value = '123';
  page.get('send-text').handlers.click();
  await page.settle();
  assert.equal(page.requests.some(request => request.method === 'POST'), false);
  assert.equal(page.get('text').value, '123');
  assert.ok(page.rendered.length > 0);
});

for (const [name, mutation] of [
  ['refused', () => response({ ok: false, error: 'not your turn' }, 409)],
  ['unknown', () => { throw new Error('connection lost after write'); }],
]) {
  test(`text is retained after a ${name} send outcome`, async () => {
    const page = fixture(request => request.method === 'POST' ? mutation() : normalReply(request));
    await page.settle();
    page.get('text').value = '123';
    page.get('send-text').handlers.click();
    await page.settle();
    assert.equal(page.get('text').value, '123');
    assert.equal(page.requests.filter(request => request.method === 'POST').length, 1);
  });
}

test('a pending text submission is sent once while a changed draft is retained', async () => {
  let complete;
  const page = fixture(request => request.method === 'POST'
    ? new Promise(resolve => { complete = resolve; }) : normalReply(request));
  await page.settle();
  page.get('text').value = '123';
  page.get('send-text').handlers.click();
  page.get('send-text').handlers.click();
  await page.settle();
  assert.equal(page.requests.filter(request => request.method === 'POST').length, 1);
  page.get('text').value = '456';
  complete(response({ ok: true }));
  await page.settle();
  assert.equal(page.get('text').value, '456');
  assert.equal(page.requests.filter(request => request.method === 'POST').length, 1);
});

test('a departed holder becomes recoverable without any machine activity', async () => {
  let departed = false;
  const page = fixture(request => request.url === '/api/v1/play/seat'
    ? response({ ...seat, controller: 'operator', controller_recoverable: departed })
    : normalReply(request));
  await page.settle();
  assert.equal(page.padButton.disabled, true);
  departed = true;
  await page.poll();
  assert.equal(page.padButton.disabled, false, 'the authoritative seat allows the next recovery move');
  assert.match(page.get('turn').textContent, /떠났어요/);
  page.padButton.handlers.click();
  await page.settle();
  assert.equal(page.requests.filter(request => request.method === 'POST').length, 1);
});

test('disconnect releases its own controller before forgetting the credential', async () => {
  const storage = new Map();
  let release;
  const page = fixture(normalReply, { storage, sessionReply: () =>
    new Promise(resolve => { release = () => resolve(response({ ok:true, connected:false })); }) });
  await page.settle();
  const disconnected = page.get('leave').handlers.click();
  await page.settle();
  assert.equal(page.get('leave').disabled, true);
  assert.equal(storage.get('masc.play.invite'), 'fixture-token');
  assert.deepEqual(page.requests.filter(request => request.method === 'POST'), [{
    url: '/api/v1/play/session', authorization: 'Bearer fixture-token', method: 'POST', body: { connected:false },
  }]);
  release();
  await disconnected;
  assert.equal(storage.size, 0);
  assert.match(page.get('turn').textContent, /연결을 끊었어요/);
});

test('a spectator disconnects without releasing another participant', async () => {
  const storage = new Map();
  const page = fixture(request => request.url === '/api/v1/play/seat'
    ? response({ ...seat, controller: 'operator' }) : normalReply(request), { storage });
  await page.settle();
  await page.get('leave').handlers.click();
  assert.deepEqual(page.requests.filter(request => request.method === 'POST').map(request => request.body), [{ connected:false }]);
  assert.equal(storage.size, 0);
});

for (const [name, release] of [
  ['refused', () => response({ ok: false }, 409)],
  ['unknown', () => { throw new Error('connection lost after release'); }],
]) {
  test(`a ${name} disconnect retains its credential across reload for recovery`, async () => {
    const storage = new Map();
    const page = fixture(normalReply, { storage, sessionReply:release });
    await page.settle();
    await page.get('leave').handlers.click();
    assert.equal(storage.get('masc.play.invite'), 'fixture-token');
    assert.match(page.get('status').textContent, /초대 연결을 유지/);
    assert.equal(page.get('leave').disabled, false, 'disconnect can be retried');
    const recovered = fixture(request => request.url === '/api/v1/play/seat'
      ? response({ ...seat, controller: null }) : normalReply(request), { storage, hash: '' });
    await recovered.settle();
    assert.ok(recovered.requests.every(request => request.authorization === 'Bearer fixture-token'));
    await recovered.get('leave').handlers.click();
    assert.equal(recovered.requests.some(request => request.method === 'POST'), name !== 'unknown');
    assert.equal(storage.size, name === 'unknown' ? 3 : 0);
    if (name === 'unknown') {
      assert.match(recovered.get('status').textContent, /운영자에게 초대 회수/);
      assert.equal(recovered.padButton.disabled, true);
    }
  });
}

test('disconnect relies on the atomic server transition even when seat reads fail', async () => {
  const storage = new Map();
  let failSeat = false;
  const page = fixture(request => failSeat && request.url === '/api/v1/play/seat'
    ? response({}, 503) : normalReply(request), { storage });
  await page.settle();
  failSeat = true;
  await page.get('leave').handlers.click();
  assert.equal(storage.get('masc.play.invite'), undefined);
  assert.deepEqual(page.requests.filter(request => request.method === 'POST').map(request => request.body), [{ connected:false }]);
  assert.equal(page.padButton.disabled, true);
});

test('disconnect drains an admitted move that acquires control and suppresses queued input', async () => {
  const storage = new Map();
  let holder = null, finishMove, finishRelease;
  const page = fixture(request => {
    if (request.url === '/api/v1/play/seat') return response({ ...seat, controller: holder });
    if (request.method === 'POST' && request.url === '/api/v1/dos/type') {
      return new Promise(resolve => { finishMove = () => { holder = 'minsu'; resolve(response({ ok: true })); }; });
    }
    return normalReply(request);
  }, { storage, sessionReply: () => new Promise(resolve => {
    finishRelease = () => { holder = null; resolve(response({ ok:true, connected:false })); };
  }) });
  await page.settle();
  page.get('text').value = '123';
  page.get('send-text').handlers.click();
  await page.settle();
  page.padButton.handlers.click();
  const disconnected = page.get('leave').handlers.click();
  page.padButton.handlers.click();
  await page.poll();
  assert.equal(page.padButton.disabled, true, 'a concurrent seat poll cannot reenable input during disconnect');
  assert.equal(storage.get('masc.play.invite'), 'fixture-token');
  assert.equal(page.requests.filter(request => request.method === 'POST').length, 1);
  finishMove();
  await page.settle();
  assert.deepEqual(page.requests.filter(request => request.method === 'POST').map(request => request.url),
    ['/api/v1/dos/type', '/api/v1/play/session']);
  assert.equal(storage.get('masc.play.invite'), 'fixture-token');
  finishRelease();
  await disconnected;
  assert.equal(holder, null);
  assert.equal(storage.size, 0);
});

test('a stale live response cannot bypass the atomic disconnect transition', async () => {
  const storage = new Map();
  let defer = false, completeDisconnect, completeLive;
  const page = fixture(request => {
    if (defer && request.url.startsWith('/api/v1/lane-addons/live')) {
      return new Promise(resolve => { completeLive = resolve; });
    }
    return normalReply(request);
  }, { storage, sessionReply: () => new Promise(resolve => { completeDisconnect = resolve; }) });
  await page.settle();
  defer = true;
  const poll = page.poll();
  const disconnected = page.get('leave').handlers.click();
  await page.settle();
  // A stale projection cannot turn the explicit disconnect into local-only cleanup.
  defer = false;
  completeDisconnect(response({ ok:true, connected:false }));
  completeLive(response({ state: 'no_machine', activity }));
  await Promise.all([poll, disconnected]);
  assert.deepEqual(page.requests.filter(request => request.method === 'POST').map(request => ({
    url: request.url, body: request.body,
  })), [{ url: '/api/v1/play/session', body: { connected:false } }]);
  assert.equal(storage.size, 0);
});

test('reopening the invitation in a disconnected tab reloads authentication', async () => {
  const storage = new Map();
  const page = fixture(normalReply, { storage });
  await page.settle();
  await page.get('leave').handlers.click();
  assert.equal(storage.size, 0);
  page.navigateFragment('#fixture-token');
  assert.equal(page.reloads, 1);
  const reopened = fixture(normalReply, { storage, hash: '#fixture-token' });
  await reopened.settle();
  assert.match(reopened.get('turn').textContent, /내 차례/);
  assert.ok(reopened.requests.every(request => request.authorization === 'Bearer fixture-token'));
});

test('a different invitation requires disconnecting the current holder first', async () => {
  const storage = new Map();
  const page = fixture(normalReply, { storage });
  await page.settle();
  page.navigateFragment('');
  assert.equal(page.reloads, 0, 'an empty fragment cannot start a reload loop');
  page.navigateFragment('#replacement-token');
  assert.equal(page.reloads, 0, 'a new identity cannot abandon the current controller');
  assert.equal(page.hash, '', 'the rejected incoming bearer is removed from the address');
  assert.equal(storage.get('masc.play.invite'), 'fixture-token');
  assert.match(page.get('status').textContent, /현재 연결을 먼저 끊은 뒤/);
  assert.equal(page.requests.some(request => request.method === 'POST'), false);
  await page.get('leave').handlers.click();
  assert.deepEqual(page.requests.filter(request => request.method === 'POST').map(request => request.url),
    ['/api/v1/play/session']);
  assert.equal(storage.size, 0);
  page.navigateFragment('#replacement-token');
  assert.equal(page.reloads, 1);
  const replacement = fixture(normalReply, { storage, hash: '#replacement-token' });
  await replacement.settle();
  assert.equal(storage.get('masc.play.invite'), 'replacement-token');
  assert.ok(replacement.requests.every(request => request.authorization === 'Bearer replacement-token'));
});

test('an uncertain release cannot be bypassed by opening a different invitation', async () => {
  const storage = new Map();
  const page = fixture(normalReply, { storage,
    sessionReply: () => { throw new Error('release acknowledgement lost'); } });
  await page.settle();
  await page.get('leave').handlers.click();
  page.navigateFragment('#replacement-token');
  assert.equal(page.reloads, 0);
  assert.equal(page.hash, '');
  assert.equal(storage.get('masc.play.invite'), 'fixture-token');
  assert.match(page.get('status').textContent, /초대 연결을 유지/);
  assert.match(page.get('status').textContent, /현재 연결을 먼저 끊은 뒤/);
  assert.equal(page.requests.filter(request => request.method === 'POST').length, 1);
});

test('opening the same invitation while connected reloads without changing its identity', async () => {
  const storage = new Map();
  const page = fixture(normalReply, { storage });
  await page.settle();
  page.navigateFragment('#fixture-token');
  assert.equal(page.reloads, 1);
  assert.equal(storage.get('masc.play.invite'), 'fixture-token');
  assert.equal(page.requests.some(request => request.method === 'POST'), false);
});

test('full-document invitation navigation preserves an existing controller identity', async () => {
  const storage = new Map([['masc.play.invite', 'existing-token']]);
  const page = fixture(normalReply, { storage, hash: '#replacement-token' });
  await page.settle();
  assert.equal(storage.get('masc.play.invite'), 'existing-token');
  assert.ok(page.requests.every(request => request.authorization === 'Bearer existing-token'));
  assert.equal(page.hash, '');
  assert.match(page.get('status').textContent, /현재 연결을 먼저 끊은 뒤/);
  await page.get('leave').handlers.click();
  assert.equal(storage.size, 0);
});

test('spectator frame polling does not repeatedly scan the seat inventory', async () => {
  const page = fixture(request => request.url === '/api/v1/play/seat'
    ? response({ ...seat, controller: 'operator' }) : normalReply(request));
  await page.settle();
  const seats = () => page.requests.filter(request => request.url === '/api/v1/play/seat').length;
  const initial = seats();
  for (let i = 0; i < 16; i++) await page.poll(300);
  assert.equal(seats(), initial, 'frame polls within the seat interval only read frames');
  await page.poll(300);
  assert.equal(seats(), initial + 1, 'the independent seat interval still detects departures');
});

test('a lost move response cannot forget a credential before the server acquires its seat', async () => {
  const storage = new Map();
  let holder = null;
  const reply = request => {
    if (request.url === '/api/v1/play/seat') return response({ ...seat, controller: holder });
    if (request.method === 'POST') {
      assert.equal(JSON.parse(storage.get('masc.play.pending')).token, 'fixture-token', 'persist before dispatch');
      throw new Error('response lost while the server is still waiting for the lane');
    }
    return normalReply(request);
  };
  const page = fixture(reply, { storage });
  await page.settle();
  page.get('text').value = '123';
  page.get('send-text').handlers.click();
  await page.settle();
  await page.get('leave').handlers.click();
  assert.equal(storage.get('masc.play.invite'), 'fixture-token');
  assert.equal(JSON.parse(storage.get('masc.play.pending')).token, 'fixture-token');
  assert.equal(page.get('text').value, '123');
  page.padButton.handlers.click();
  await page.settle();
  assert.equal(page.requests.filter(r => r.method === 'POST').length, 1);

  // Even a free seat on reload is not a receipt for the delayed request.
  const recovered = fixture(reply, { storage, hash: '#new-token' });
  await recovered.settle();
  await recovered.get('leave').handlers.click();
  assert.equal(recovered.requests.some(r => r.method === 'POST'), false);
  assert.ok(recovered.requests.every(r => r.authorization === 'Bearer fixture-token'));
  assert.equal(JSON.parse(storage.get('masc.play.pending')).token, 'fixture-token');
  holder = 'minsu';
  await recovered.poll();
  assert.equal(recovered.padButton.disabled, true);
  assert.equal(storage.get('masc.play.invite'), 'fixture-token', 'retain the late controller identity');
  assert.match(recovered.get('status').textContent, /운영자에게 초대 회수/);
});

test('reload during an unresolved fetch retains the outstanding operation', async () => {
  const storage = new Map();
  const page = fixture(request => request.method === 'POST' ? new Promise(() => {}) : normalReply(request), { storage });
  await page.settle();
  page.padButton.handlers.click();
  await page.settle();
  const reloaded = fixture(normalReply, { storage, hash: '' });
  await reloaded.settle();
  await reloaded.get('leave').handlers.click();
  assert.equal(reloaded.requests.some(r => r.method === 'POST'), false);
  assert.equal(JSON.parse(storage.get('masc.play.pending')).token, 'fixture-token');
});

for (const status of [401, 403, 503]) {
  test(`HTTP ${status} on a later read cannot settle an earlier lost write`, async () => {
    const storage = new Map([
      ['masc.play.invite', 'fixture-token'], ['masc.play.pending', JSON.stringify({ token: 'fixture-token', operation: 'previous' })],
    ]);
    const page = fixture(() => response({ auth_error_code: 'invalid_token', error: 'unavailable' }, status), { storage, hash: '' });
    await page.settle();
    await page.get('leave').handlers.click();
    assert.equal(storage.get('masc.play.invite'), 'fixture-token');
    assert.equal(JSON.parse(storage.get('masc.play.pending')).token, 'fixture-token');
    assert.equal(page.requests.some(r => r.method === 'POST'), false);
  });
}

test('unavailable tab storage prevents dispatch instead of losing reload recovery', async () => {
  const storage = new Map();
  const page = fixture(normalReply, { storage });
  await page.settle();
  storage.set = () => { throw new Error('storage denied'); };
  page.padButton.handlers.click();
  await page.settle();
  assert.equal(page.requests.some(r => r.method === 'POST'), false);
  assert.match(page.get('status').textContent, /입력을 보내지 않았어요/);
});

for (const [name, reply] of [
  ['success', response({ ok: true })],
  ['DOS refusal', response({ ok: false, message: 'not your turn' }, 409)],
  ['pad refusal', response({ code: 'program_changed', error: 'game changed' }, 409)],
]) {
  test(`an acknowledged ${name} clears its own marker before a failing seat read`, async () => {
    const storage = new Map();
    let sent = false;
    const page = fixture(request => {
      if (request.method === 'POST') { sent = true; return reply; }
      if (sent && request.url === '/api/v1/play/seat') throw new Error('seat unavailable');
      return normalReply(request);
    }, { storage });
    await page.settle();
    page.padButton.handlers.click();
    await page.settle();
    assert.equal(storage.has('masc.play.pending'), false);
    assert.equal(storage.get('masc.play.invite'), 'fixture-token');
    assert.doesNotMatch(page.get('status').textContent, /운영자에게 초대 회수/);
  });
}

test('a malformed mutation response remains unknown rather than enabling a retry', async () => {
  const storage = new Map();
  const page = fixture(request => request.method === 'POST' ? response({}, 502) : normalReply(request), { storage });
  await page.settle();
  page.padButton.handlers.click();
  await page.settle();
  await page.get('leave').handlers.click();
  assert.equal(JSON.parse(storage.get('masc.play.pending')).token, 'fixture-token');
  assert.equal(page.requests.filter(r => r.method === 'POST').length, 1);
});

for (const action of ['disconnect', 'input', 'auth failure']) {
  test(`a restored older document cannot clear a newer unknown write via ${action}`, async () => {
    const storage = new Map();
    let authFails = false;
    const reply = request => authFails ? response({}, 401)
      : request.url === '/api/v1/play/seat' ? response({ ...seat, controller: null }) : normalReply(request);
    const cached = fixture(reply, { storage });
    await cached.settle();
    const newer = fixture(request => request.method === 'POST'
      ? Promise.reject(new Error('lost response')) : reply(request), { storage, hash: '' });
    await newer.settle();
    newer.padButton.handlers.click();
    await newer.settle();
    const marker = storage.get('masc.play.pending');
    cached.restoreFromCache();
    assert.equal(cached.reloads, 1, 'bfcache restoration reloads its identity');
    // Boundary guards also work before the requested reload has completed.
    if (action === 'disconnect') await cached.get('leave').handlers.click();
    else if (action === 'input') { cached.padButton.handlers.click(); await cached.settle(); }
    else { authFails = true; await cached.poll(); }
    assert.equal(cached.requests.some(r => r.method === 'POST'), false);
    assert.equal(storage.get('masc.play.pending'), marker);
    assert.equal(storage.get('masc.play.invite'), 'fixture-token');
  });
}

test('an old document cannot forget a replacement identity', async () => {
  const storage = new Map();
  const cached = fixture(request => request.url === '/api/v1/play/seat'
    ? response({ ...seat, controller: null }) : normalReply(request), { storage });
  await cached.settle();
  storage.set('masc.play.invite', 'replacement-token');
  await cached.get('leave').handlers.click();
  assert.equal(storage.get('masc.play.invite'), 'replacement-token');
  assert.equal(cached.requests.some(r => r.method === 'POST'), false);
});

test('an old acknowledgement cannot remove a different operation marker', async () => {
  const storage = new Map();
  let acknowledge;
  const page = fixture(request => request.method === 'POST'
    ? new Promise(resolve => { acknowledge = () => resolve(response({ ok: true })); }) : normalReply(request), { storage });
  await page.settle();
  page.padButton.handlers.click();
  await page.settle();
  const replacement = JSON.stringify({ token: 'fixture-token', operation: 'different-operation' });
  storage.set('masc.play.pending', replacement);
  acknowledge();
  await page.settle();
  assert.equal(storage.get('masc.play.pending'), replacement);
  await page.get('leave').handlers.click();
  assert.equal(storage.get('masc.play.invite'), 'fixture-token');
  assert.equal(page.requests.filter(r => r.method === 'POST').length, 1);
});

test('late auth failure after disconnect cannot clear a later invitation', async () => {
  const storage = new Map();
  let deferred = false, completeSeat;
  const page = fixture(request => {
    if (deferred && request.url === '/api/v1/play/seat') {
      deferred = false;
      return new Promise(resolve => { completeSeat = resolve; });
    }
    return request.url === '/api/v1/play/seat'
      ? response({ ...seat, controller: null }) : normalReply(request);
  }, { storage });
  await page.settle();
  deferred = true;
  page.get('pass-to').handlers.focus();
  await page.settle();
  await page.get('leave').handlers.click();
  assert.equal(storage.size, 0);
  storage.set('masc.play.invite', 'later-token');
  completeSeat(response({}, 401));
  await page.settle();
  assert.equal(storage.get('masc.play.invite'), 'later-token');
});

test('failure to load a retained credential never deletes the unread identity', async () => {
  const storage = new Map([['masc.play.invite', 'unread-token']]);
  storage.get = () => { throw new Error('storage read unavailable'); };
  const page = fixture(normalReply, { storage, hash: '' });
  await page.settle();
  assert.equal(page.requests.length, 0);
  assert.equal(Map.prototype.get.call(storage, 'masc.play.invite'), 'unread-token');
});

test('credential removal failure keeps disconnect retryable and game input disabled', async () => {
  const storage = new Map();
  let connected = true;
  const page = fixture(request => request.url === '/api/v1/play/seat'
    ? response({ ...seat, connected }) : normalReply(request), { storage,
    sessionReply: ({ body }) => { connected = body.connected; return response({ ok:true, connected }); } });
  await page.settle();
  storage.delete = key => { if (key === 'masc.play.invite') throw new Error('storage revoked'); return Map.prototype.delete.call(storage, key); };
  await page.get('leave').handlers.click();
  assert.equal(connected, false);
  assert.equal(storage.get('masc.play.invite'), 'fixture-token');
  assert.match(page.get('status').textContent, /지우지 못했어요/);
  assert.equal(page.get('leave').disabled, false);
  await page.poll();
  assert.equal(page.padButton.disabled, true);
  assert.equal(page.requests.some(request => request.url === '/api/v1/play/session' && request.body.connected), false,
    'ordinary polling cannot reconnect a departed participant');
  storage.delete = key => Map.prototype.delete.call(storage, key);
  await page.get('leave').handlers.click();
  assert.equal(storage.size, 0);
});

test('opening a departed invitation reconnects explicitly without a game move', async () => {
  let connected = false;
  const page = fixture(request => request.url === '/api/v1/play/seat'
    ? response({ ...seat, connected, controller:null }) : normalReply(request), {
    sessionReply: ({ body }) => { connected = body.connected; return response({ ok:true, connected }); }
  });
  await page.settle();
  assert.deepEqual(page.requests.filter(request => request.method === 'POST').map(request => [request.url, request.body]),
    [['/api/v1/play/session', { connected:true }]]);
  assert.equal(page.padButton.disabled, false);
});

test('reloading after departure cleanup fails does not rejoin without an invitation fragment', async () => {
  const storage = new Map();
  let connected = true;
  const reply = request => request.url === '/api/v1/play/seat'
    ? response({ ...seat, connected, controller:null }) : normalReply(request);
  const sessionReply = ({ body }) => { connected = body.connected; return response({ ok:true, connected }); };
  const page = fixture(reply, { storage, sessionReply });
  await page.settle();
  storage.delete = key => { if (key === 'masc.play.invite') throw new Error('storage revoked'); return Map.prototype.delete.call(storage, key); };
  await page.get('leave').handlers.click();
  assert.equal(connected, false);
  const reloaded = fixture(reply, { storage, hash:'', sessionReply });
  await reloaded.settle();
  await reloaded.poll();
  assert.equal(connected, false);
  assert.equal(reloaded.padButton.disabled, true);
  assert.equal(reloaded.requests.some(request => request.method === 'POST'), false);
  const reopened = fixture(reply, { storage, sessionReply });
  await reopened.settle();
  assert.equal(connected, true, 'explicitly opening the invitation still rejoins');
});

test('explicit reconnect retries transient refusals while the machine stays idle', async () => {
  let connected = false, attempts = 0;
  const page = fixture(request => request.url === '/api/v1/play/seat'
    ? response({ ...seat, connected, controller:null }) : normalReply(request), {
    sessionReply: ({ body }) => {
      if (++attempts < 3) return response({ ok:false, error:'participation unavailable' }, 503);
      connected = body.connected;
      return response({ ok:true, connected });
    }
  });
  await page.settle();
  assert.equal(attempts, 1);
  await page.poll();
  assert.equal(attempts, 2);
  await page.poll();
  assert.equal(attempts, 3);
  assert.equal(page.padButton.disabled, false);
  await page.poll();
  assert.equal(attempts, 3, 'successful reconnect settles the intent');
});

test('a plain-text 413 settles the rejected input without losing its draft', async () => {
  const storage = new Map();
  const page = fixture(request => request.method === 'POST'
    ? { status:413, json:async () => { throw new SyntaxError('plain text'); } }
    : normalReply(request), { storage });
  await page.settle();
  page.get('text').value = 'too large';
  page.get('send-text').handlers.click();
  await page.settle();
  assert.equal(page.get('text').value, 'too large');
  assert.equal(storage.has('masc.play.pending'), false);
  assert.equal(page.padButton.disabled, false);
  assert.match(page.get('status').textContent, /413/);
  await page.get('leave').handlers.click();
  assert.equal(storage.size, 0, 'a refused input does not block departure');
});

test('a pre-dispatch 429 preserves the draft and allows a later retry', async () => {
  const storage = new Map();
  let attempts = 0;
  const page = fixture(request => request.url === '/api/v1/dos/type'
    ? ++attempts === 1 ? response({ error:'Too Many Requests', message:'Try later' }, 429)
      : response({ ok:true, data:{ keys_pressed:3 } })
    : normalReply(request), { storage });
  await page.settle();
  page.get('text').value = '123';
  page.get('send-text').handlers.click();
  await page.settle();
  assert.equal(storage.has('masc.play.pending'), false);
  assert.equal(page.get('text').value, '123');
  assert.equal(page.padButton.disabled, false);
  page.get('send-text').handlers.click();
  await page.settle();
  assert.equal(page.get('text').value, '');
  assert.equal(attempts, 2);
  await page.get('leave').handlers.click();
  assert.equal(storage.size, 0);
});

for (const status of [401, 403]) {
  test(`storage-blocked observation ends on terminal authentication ${status}`, async () => {
    const storage = new Map([['masc.play.invite', 'unread-identity']]);
    storage.get = () => { throw new Error('storage blocked'); };
    const page = fixture(() => response({}, status), { storage });
    await page.settle();
    assert.match(page.get('turn').textContent, /초대가 끝났거나 회수됐어요/);
    assert.equal(page.get('leave').disabled, true);
    assert.equal(page.requests.some(request => request.method === 'POST'), false,
      'concurrent observation reads cannot send a mutation after terminal authentication');
    assert.equal(page.timerCount, 0);
    assert.equal(Map.prototype.get.call(storage, 'masc.play.invite'), 'unread-identity');
  });
}

test('disconnect does not wait for an initial seat read that never answers', async () => {
  const storage = new Map();
  let finishSeat;
  const page = fixture(request => request.url === '/api/v1/play/seat'
    ? new Promise(resolve => { finishSeat = () => resolve(response({ ...seat, connected:false })); })
    : normalReply(request), { storage });
  await page.settle();
  let completed = false;
  page.get('leave').handlers.click().then(() => { completed = true; });
  await page.settle();
  assert.equal(completed, true);
  assert.equal(storage.size, 0);
  assert.deepEqual(page.requests.filter(request => request.method === 'POST').map(request => request.body), [{ connected:false }]);
  finishSeat();
  await page.settle();
  assert.equal(page.requests.filter(request => request.method === 'POST').length, 1, 'late seat cannot reconnect');
});

test('disconnect drains an already admitted reconnect before departing', async () => {
  const storage = new Map();
  let finishReconnect;
  const page = fixture(request => request.url === '/api/v1/play/seat'
    ? response({ ...seat, connected:false }) : normalReply(request), { storage,
    sessionReply: ({ body }) => body.connected
      ? new Promise(resolve => { finishReconnect = () => resolve(response({ ok:true, connected:true })); })
      : response({ ok:true, connected:false }) });
  await page.settle();
  let completed = false;
  page.get('leave').handlers.click().then(() => { completed = true; });
  await page.settle();
  assert.equal(completed, false);
  assert.equal(page.requests.filter(request => request.method === 'POST').length, 1);
  finishReconnect();
  await page.settle();
  assert.equal(completed, true);
  assert.deepEqual(page.requests.filter(request => request.method === 'POST').map(request => request.body),
    [{ connected:true }, { connected:false }]);
  assert.equal(storage.size, 0);
});

test('an old initial seat response cannot reconnect after a newer document disconnects', async () => {
  const storage = new Map();
  let completeSeat;
  const old = fixture(request => request.url === '/api/v1/play/seat'
    ? new Promise(resolve => { completeSeat = resolve; }) : normalReply(request), { storage });
  const current = fixture(normalReply, { storage, hash:'' });
  await current.settle();
  await current.get('leave').handlers.click();
  assert.equal(storage.size, 0);
  completeSeat(response({ ...seat, connected:false, controller:null }));
  await old.settle();
  assert.equal(old.requests.some(request => request.method === 'POST'), false);
  assert.equal(storage.size, 0);
});

test('a pending old operation cannot reactivate a departed invitation on reload', async () => {
  const storage = new Map([['masc.play.invite', 'fixture-token'],
    ['masc.play.pending', JSON.stringify({ token:'fixture-token', operation:'old' })]]);
  const page = fixture(request => request.url === '/api/v1/play/seat'
    ? response({ ...seat, connected:false }) : normalReply(request), { storage, hash:'' });
  await page.settle();
  assert.equal(page.requests.some(request => request.method === 'POST'), false);
  assert.equal(page.padButton.disabled, true);
});

test('missing participation authority is not treated as a connected session', async () => {
  const page = fixture(request => request.url === '/api/v1/play/seat'
    ? response({ ...seat, connected:undefined }) : normalReply(request));
  await page.settle();
  assert.equal(page.padButton.disabled, true);
  assert.match(page.get('status').textContent, /자리 정보를 읽지 못/);
});

for (const [count, remaining] of [[0, '123'], [1, '23'], [3, '']]) {
  test(`a DOS text receipt for ${count} keys retains exactly the unpressed suffix`, async () => {
    const page = fixture(request => request.url === '/api/v1/dos/type'
      ? response({ ok:true, data:{ keys_pressed:count } }) : normalReply(request));
    await page.settle();
    page.get('text').value = '123';
    page.get('send-text').handlers.click();
    await page.settle();
    assert.equal(page.get('text').value, remaining);
    assert.equal(page.requests.filter(request => request.method === 'POST').length, 1, 'no automatic suffix replay');
    if (remaining) assert.match(page.get('status').textContent, /일부만 입력/);
  });
}

test('a partial text receipt preserves a draft edited while the request ran', async () => {
  let finish;
  const page = fixture(request => request.url === '/api/v1/dos/type'
    ? new Promise(resolve => { finish = () => resolve(response({ ok:true, data:{ keys_pressed:1 } })); }) : normalReply(request));
  await page.settle();
  page.get('text').value = '123';
  page.get('send-text').handlers.click();
  await page.settle();
  page.get('text').value = '456';
  finish();
  await page.settle();
  assert.equal(page.get('text').value, '456');
});

for (const count of [undefined, -1, 4, 0.5]) {
  test(`an invalid text count ${count} keeps the entire draft with an explanation`, async () => {
    const page = fixture(request => request.url === '/api/v1/dos/type'
      ? response({ ok:true, data:{ keys_pressed:count } }) : normalReply(request));
    await page.settle();
    page.get('text').value = '123';
    page.get('send-text').handlers.click();
    await page.settle();
    assert.equal(page.get('text').value, '123');
    assert.match(page.get('status').textContent, /글자 수를 확인하지 못/);
  });
}


test('first observed activity reconnects a departed invitation after a transient initial seat failure', async () => {
  let reads = 0, connected = false;
  const page = fixture(request => request.url === '/api/v1/play/seat'
    ? ++reads === 1 ? response({}, 503) : response({ ...seat, connected, controller:null }) : normalReply(request), {
    sessionReply: ({ body }) => { connected = body.connected; return response({ ok:true, connected }); }
  });
  await page.settle();
  assert.equal(reads, 3, 'initial failure, immediate activity read, and connected confirmation');
  assert.equal(page.padButton.disabled, false);
  assert.deepEqual(page.requests.filter(request => request.method === 'POST').map(request => request.body), [{ connected:true }]);
  await page.poll();
  assert.equal(page.requests.filter(request => request.method === 'POST').length, 1);
});

for (const [count, remaining] of [[1, '가x'], [3, 'x']]) {
  test(`a ${count}-byte text acknowledgement preserves Unicode boundaries`, async () => {
    const page = fixture(request => request.url === '/api/v1/dos/type'
      ? response({ ok:true, data:{ keys_pressed:count } }) : normalReply(request));
    await page.settle();
    page.get('text').value = '가x';
    page.get('send-text').handlers.click();
    await page.settle();
    assert.equal(page.get('text').value, remaining);
    if (count === 1) assert.match(page.get('status').textContent, /글자 중간/);
  });
}

for (const [name, receipt, remaining] of [
  ['successful', response({ ok:true, data:{ keys_pressed:1 } }), '23'],
  ['refused', response({ ok:false, message:'try later' }, 409), '123'],
]) {
  test(`disconnect drains a ${name} write without waiting for its stalled seat projection`, async () => {
    const storage = new Map();
    let afterWrite = false, finishProjection;
    const page = fixture(request => {
      if (request.url === '/api/v1/dos/type') { afterWrite = true; return receipt; }
      if (afterWrite && request.url === '/api/v1/play/seat')
        return new Promise(resolve => { finishProjection = resolve; });
      return normalReply(request);
    }, { storage });
    await page.settle();
    page.get('text').value = '123';
    page.get('send-text').handlers.click();
    await page.settle();
    assert.equal(typeof finishProjection, 'function', 'post-write read really is pending');
    assert.equal(storage.has('masc.play.pending'), false, 'write has a terminal receipt');
    assert.equal(page.get('text').value, remaining, 'the text receipt does not wait for projection');
    let disconnected = false;
    page.get('leave').handlers.click().then(() => { disconnected = true; });
    await page.settle();
    assert.equal(disconnected, true, 'no read response is needed to finish departure');
    assert.equal(storage.size, 0);
    assert.deepEqual(page.requests.filter(request => request.method === 'POST').map(request => request.url),
      ['/api/v1/dos/type', '/api/v1/play/session']);
    finishProjection(response(seat));
    await page.settle();
    assert.match(page.get('turn').textContent, /연결을 끊었어요/);
    assert.equal(page.padButton.disabled, true, 'late projection cannot revive ended controls');
    assert.equal(storage.size, 0);
  });
}

test('new activity updates controller ownership immediately inside the recovery interval', async () => {
  let controller = 'operator', version = 1;
  const page = fixture(request => request.url === '/api/v1/play/seat'
    ? response({ ...seat, controller }) : request.url.includes('/live?')
      ? response({ ...frame, activity:[{ at:version, who:controller, action:'handoff' }] }) : normalReply(request));
  await page.settle();
  const reads = () => page.requests.filter(request => request.url === '/api/v1/play/seat').length;
  const before = reads();
  controller = 'minsu'; version += 1;
  await page.poll(300);
  assert.equal(reads(), before + 1);
  assert.equal(page.padButton.disabled, false, 'new owner becomes playable before five seconds');
  controller = 'operator'; version += 1;
  await page.poll(300);
  assert.equal(reads(), before + 2);
  assert.equal(page.padButton.disabled, true, 'previous owner is disabled on the next changed frame');
  await page.poll(4999);
  assert.equal(reads(), before + 2, 'unchanged observer recovery keeps its cadence');
  await page.poll(1);
  assert.equal(reads(), before + 3, 'idle departure discovery still runs after five seconds');
});

test('a failed activity-triggered read retries unchanged activity only at the recovery cadence', async () => {
  let version = 1, fail = false;
  const page = fixture(request => request.url === '/api/v1/play/seat'
    ? fail ? response({}, 503) : response(seat) : request.url.includes('/live?')
      ? response({ ...frame, activity:[{ at:version, who:'operator', action:'handoff' }] }) : normalReply(request));
  await page.settle();
  const reads = () => page.requests.filter(request => request.url === '/api/v1/play/seat').length;
  const before = reads();
  fail = true; version += 1;
  await page.poll(300);
  assert.equal(reads(), before + 1);
  assert.equal(page.padButton.disabled, true);
  fail = false;
  await page.poll(4999);
  assert.equal(reads(), before + 1, 'failed acknowledgement is not a new activity edge');
  await page.poll(1);
  assert.equal(reads(), before + 2);
  assert.equal(page.padButton.disabled, false);
});

test('changed activity does not accelerate refused explicit reconnect writes', async () => {
  let version = 1, attempts = 0;
  const page = fixture(request => request.url === '/api/v1/play/seat'
    ? response({ ...seat, connected:false, controller:null }) : request.url.includes('/live?')
      ? response({ ...frame, activity:[{ at:version, who:'operator', action:'move' }] }) : normalReply(request), {
    sessionReply: () => { attempts += 1; return response({ ok:false, error:'unavailable' }, 503); },
  });
  await page.settle();
  assert.equal(attempts, 1, 'first activity does not immediately retry the refused reconnect');
  version += 1;
  await page.poll(300);
  assert.equal(attempts, 1);
  version += 1;
  await page.poll(4700);
  assert.equal(attempts, 2, 'new authority may retry once its independent reconnect cadence is due');
});

for (const initiallyConnected of [true, false]) {
  test(`idle free-controller participation observes external ${initiallyConnected ? 'departure' : 'reconnect'} without a move`, async () => {
    const storage = new Map([['masc.play.invite', 'fixture-token']]);
    let connected = initiallyConnected;
    const page = fixture(request => request.url === '/api/v1/play/seat'
      ? response({ ...seat, controller:null, connected }) : request.url.includes('/live?')
        ? response({ ...frame, activity:[] }) : normalReply(request), { storage, hash:'' });
    await page.settle();
    await page.poll(5000); // First idle scan acknowledges the unchanged empty activity.
    const reads = () => page.requests.filter(request => request.url === '/api/v1/play/seat').length;
    const before = reads();
    assert.equal(page.padButton.disabled, !initiallyConnected);
    connected = !initiallyConnected;
    await page.poll(4999);
    assert.equal(reads(), before, 'ordinary frame polls do not rescan credentials');
    assert.equal(page.padButton.disabled, !initiallyConnected);
    await page.poll(1);
    assert.equal(reads(), before + 1, 'participation is refreshed even with no controller or activity');
    assert.equal(page.padButton.disabled, initiallyConnected);
    assert.equal(page.get('send-text').disabled, initiallyConnected);
    assert.equal(page.requests.some(request => request.method === 'POST'), false, 'observation neither reconnects nor sends input');
    assert.equal(storage.get('masc.play.invite'), 'fixture-token');
  });
}

for (const status of [401, 403]) {
  test(`terminal ${status} retires an initialized page after storage access is revoked`, async () => {
    let blocked = false;
    let rejected = false;
    const backing = new Map();
    const storage = {
      get(key) { if (blocked) throw new Error('storage revoked'); return backing.get(key); },
      set(key, value) { if (blocked) throw new Error('storage revoked'); backing.set(key, value); },
      delete(key) { if (blocked) throw new Error('storage revoked'); return backing.delete(key); },
    };
    const page = fixture(({url}) => {
      if (rejected) return response({}, status);
      if (url === '/api/v1/play/seat') return response(seat);
      if (url === '/api/v1/play/pad') return response(layout);
      return response(frame);
    }, {storage});
    await page.settle();
    blocked = true; rejected = true;
    await page.poll();
    await page.settle();
    assert.match(page.get('turn').textContent, /초대가 끝났거나/);
    const count = page.requests.length;
    if (page.timerCount) await page.poll();
    assert.equal(page.requests.length, count, 'invalid bearer does not keep polling');
    assert.equal(page.get('send-text').disabled, true);
    assert.ok(backing.size > 0, 'inaccessible persisted evidence remains intact');
  });
}

test('seat authority keeps its own cadence while the live frame request never answers', async () => {
  let current = seat;
  const page = fixture(request => {
    if (request.url.startsWith('/api/v1/lane-addons/live')) return new Promise(() => {});
    if (request.url === '/api/v1/play/seat') return response(current);
    if (request.url === '/api/v1/play/pad') return response(layout);
    return response({ ok: true });
  });
  await page.settle();
  const seatReads = () => page.requests.filter(r => r.url === '/api/v1/play/seat').length;
  assert.equal(page.timerCount, 0, 'the frame poll waits on its stalled live request');
  assert.equal(page.padButton.disabled, false);
  const before = seatReads();
  // Another tab disconnected this invitation; no frame response will say so.
  current = { ...seat, connected: false };
  await page.seatTick();
  assert.equal(seatReads(), before + 1, 'authority is read without a live response');
  assert.equal(page.padButton.disabled, true, 'controls follow the new authority');
  current = seat;
  await page.seatTick();
  assert.equal(seatReads(), before + 2, 'the cadence continues');
  assert.equal(page.padButton.disabled, false);
});

test('a stalled pad layout read is replaced at the recovery cadence', async () => {
  let stalled;
  const page = fixture(request => {
    if (request.url === '/api/v1/play/pad' && stalled === undefined) {
      stalled = request;
      return new Promise(() => {});
    }
    return normalReply(request);
  });
  await page.settle();
  const padReads = () => page.requests.filter(r => r.url === '/api/v1/play/pad').length;
  assert.equal(padReads(), 1);
  assert.equal(page.get('pad').hidden, true, 'the pad waits for its layout');
  await page.poll(300);
  assert.equal(padReads(), 1, 'a recent layout read is not replaced at frame cadence');
  await page.poll(5000);
  assert.equal(stalled.signal.aborted, true, 'the stalled read is retired');
  assert.equal(padReads(), 2, 'one replacement read');
  assert.equal(page.get('pad').hidden, false, 'the recovered layout shows the pad');
});

test('live activity from a queued input does not drop the next queued key', async () => {
  let holdSeat = false, liveActivity = activity, finishFirst;
  const page = fixture(request => {
    if (request.url === '/api/v1/play/seat') return holdSeat ? new Promise(() => {}) : response(seat);
    if (request.method === 'POST' && request.url === '/api/v1/play/pad' && finishFirst === undefined)
      return new Promise(resolve => { finishFirst = () => resolve(response({ ok: true })); });
    if (request.url.startsWith('/api/v1/lane-addons/live')) return response({ ...frame, activity: liveActivity });
    return normalReply(request);
  });
  await page.settle();
  const presses = () => page.requests.filter(r => r.method === 'POST' && r.url === '/api/v1/play/pad').length;
  page.padButton.handlers.click();
  page.padButton.handlers.click();
  await page.settle();
  assert.equal(presses(), 1, 'input is serialized');
  // The first press is visible in the live feed before the second is sent.
  holdSeat = true;
  liveActivity = [{ at: 2, who: 'minsu', action: 'pad BTN_SOUTH' }, ...activity];
  const seatReads = page.requests.filter(r => r.url === '/api/v1/play/seat').length;
  await page.poll(300);
  assert.equal(page.requests.filter(r => r.url === '/api/v1/play/seat').length, seatReads,
    'the authority read waits for the queue');
  finishFirst();
  await page.settle();
  assert.equal(presses(), 2, 'the queued key is sent');
  assert.equal(page.requests.filter(r => r.url === '/api/v1/play/seat').length, seatReads + 1,
    'one authority read follows the drained queue');
});

test('seat recovery cadence replaces a stalled authority request without machine activity', async () => {
  let stalled;
  let hold = false;
  const page = fixture(request => {
    if (request.url === '/api/v1/play/seat') {
      if (hold && !stalled) { stalled = request; return new Promise(() => {}); }
      return response(seat);
    }
    if (request.url === '/api/v1/play/pad') return response(layout);
    return response(frame);
  });
  await page.settle();
  hold = true;
  await page.poll(5000);
  assert.equal(page.get('send-text').disabled, true);
  const reads = page.requests.filter(r => r.url === '/api/v1/play/seat').length;
  await page.poll(5000);
  await page.settle();
  assert.equal(stalled.signal.aborted, true);
  assert.equal(page.requests.filter(r => r.url === '/api/v1/play/seat').length, reads + 1);
  assert.equal(page.get('send-text').disabled, false);
});


test('a stalled periodic seat read cannot stop live frames or admit stale controls', async () => {
  let seatReads = 0;
  let liveReads = 0;
  let resumeSeat;
  const heldSeat = new Promise(resolve => { resumeSeat = resolve; });
  const page = fixture(({ url, method }) => {
    if (url === '/api/v1/play/seat') {
      seatReads += 1;
      return seatReads === 3 ? heldSeat
        : response(seatReads > 3 ? { ...seat, controller: 'operator' } : seat);
    }
    if (url === '/api/v1/play/pad') return response(layout);
    if (method === 'POST') return response({ ok: true });
    liveReads += 1;
    return response({ ...frame, change_count: liveReads,
      screen: { ...frame.screen, rgb_base64: liveReads >= 3 ? 'AAAA' : '/wAA' },
      activity: [{ at: liveReads, who: 'operator', action: 'frame-' + liveReads }] });
  });
  await page.settle();
  assert.match(page.get('turn').textContent, /내 차례/);
  await page.poll(5000);
  assert.equal(seatReads, 3, 'periodic authority request is pending');
  const before = liveReads;
  await page.poll(300);
  await page.poll(300);
  assert.equal(liveReads, before + 2, 'subsequent live polls keep completing');
  assert.equal(page.timerCount, 1, 'the live loop schedules its next frame');
  assert.equal(seatReads, 3, 'pending periodic authority is coalesced');
  assert.deepEqual(page.rendered.at(-1), [0, 0, 0, 255]);
  assert.equal(page.get('activity').children[0].textContent, 'operator · frame-' + liveReads);
  page.padButton.handlers.click();
  await page.settle();
  assert.equal(page.requests.some(r => r.method === 'POST'), false, 'stale seat cannot authorize input');
  resumeSeat(response(seat));
  await page.settle();
  await page.settle();
  assert.equal(seatReads, 4, 'activity refresh debt starts another authority read without a user action');
  await page.poll(5000);
  assert.equal(seatReads, 5, 'obsolete frame request cannot block later authority polling');
  assert.equal(page.get('turn').textContent, 'operator 님 차례예요', 'old seat cannot restore stale control');
});


for (const replacement of ['no_machine then new program', 'new incarnation with the same program']) {
  test('an old pad response cannot restore controls after ' + replacement, async () => {
    let phase = 'A';
    let padReads = 0;
    let releaseOld;
    let oldRequest;
    const oldPad = new Promise(resolve => { releaseOld = resolve; });
    const newProgram = replacement === 'no_machine then new program' ? 'program-B' : seat.saves_name;
    const newLayout = { saves_name: newProgram,
      buttons: [{ ...layout.buttons[0], label: 'new-layout' }] };
    const page = fixture(request => {
      const { url } = request;
      if (url === '/api/v1/play/seat') return response({ ...seat,
        machine: phase !== 'empty', saves_name: phase === 'empty' ? null
          : phase === 'B' ? newProgram : seat.saves_name });
      if (url === '/api/v1/play/pad') {
        if (++padReads === 1) { oldRequest = request; return oldPad; }
        return response(newLayout);
      }
      if (phase === 'empty') return response({ state: 'no_machine', activity: [] });
      return response({ ...frame, change_count: phase === 'B' ? 2 : 1,
        incarnation: phase === 'B' ? 'machine-B' : 'machine-A',
        activity: [{ at: phase === 'B' ? 2 : 1, who: 'operator', action: phase }] });
    });
    await page.settle();
    assert.equal(padReads, 1, 'old layout request is still held');
    if (replacement === 'no_machine then new program') {
      phase = 'empty';
      await page.poll(300);
      assert.equal(page.get('pad').hidden, true, 'eject clears old controls while GET is pending');
    }
    phase = 'B';
    await page.poll(300);
    assert.equal(padReads, 2, 'replacement layout can be read without waiting for obsolete GET');
    assert.equal(page.get('pad').hidden, false);
    assert.equal(page.padButton.textContent, 'new-layout');
    assert.equal(oldRequest.signal.aborted, true, 'retirement frees the obsolete HTTP request');
    releaseOld(replacement === 'no_machine then new program' ? response({}, 401) : response(layout));
    await page.settle();
    assert.equal(page.padButton.textContent, 'new-layout', 'late old layout cannot restore stale buttons');
    assert.equal(page.get('pad').hidden, false);
  });
}


for (const replacement of ['eject then replacement', 'direct incarnation replacement']) {
  test('a stalled old seat cannot block fresh authority after ' + replacement, async () => {
    let phase = 'A';
    let seatReads = 0;
    let releaseOld;
    const oldSeat = new Promise(resolve => { releaseOld = resolve; });
    const page = fixture(({ url }) => {
      if (url === '/api/v1/play/seat') {
        seatReads += 1;
        if (seatReads === 3) return oldSeat;
        return response({ ...seat, machine: phase !== 'empty',
          saves_name: phase === 'empty' ? null : phase === 'B' ? 'program-B' : seat.saves_name,
          controller: phase === 'B' ? 'operator' : seat.controller });
      }
      if (url === '/api/v1/play/pad') return response({ ...layout,
        saves_name: phase === 'B' ? 'program-B' : seat.saves_name });
      if (phase === 'empty') return response({ state: 'no_machine', activity: [] });
      return response({ ...frame, incarnation: phase === 'B' ? 'machine-B' : 'machine-A',
        // Keep the activity identical: incarnation itself must revoke A.
        activity });
    });
    await page.settle();
    await page.poll(5000);
    assert.equal(seatReads, 3, 'old A periodic seat response is held');
    if (replacement === 'eject then replacement') {
      phase = 'empty';
      await page.poll(300);
      assert.equal(page.get('pad').hidden, true);
    }
    phase = 'B';
    await page.poll(300);
    assert.equal(page.get('turn').textContent, 'operator 님 차례예요');
    const observed = seatReads;
    assert.ok(observed > 3, 'replacement requested its own authority before old GET settled');
    await page.poll(5000);
    assert.equal(seatReads, observed + 1, 'new owner keeps periodic authority refresh enabled');
    releaseOld(replacement === 'eject then replacement' ? response({}, 401) : response(seat));
    await page.settle();
    assert.equal(page.get('turn').textContent, 'operator 님 차례예요', 'late A cannot restore control');
  });
}


test('held initial seat authority cannot block first or subsequent live observations', async () => {
  let seatReads = 0;
  let liveReads = 0;
  const held = new Promise(() => {});
  const page = fixture(({ url }) => {
    if (url === '/api/v1/play/seat') { seatReads += 1; return held; }
    if (url === '/api/v1/play/pad') return response(layout);
    liveReads += 1;
    return response({ ...frame, change_count: liveReads,
      activity: [{ at: liveReads, who: 'operator', action: 'initial-frame-' + liveReads }] });
  });
  await page.settle();
  assert.equal(liveReads, 1, 'first frame does not wait for unread authority');
  // Discovering the first actual machine incarnation retires the boot read
  // and owns one new authority request; subsequent ticks coalesce that owner.
  assert.equal(seatReads, 2);
  await page.poll(300);
  await page.poll(5000);
  assert.equal(liveReads, 3);
  assert.equal(seatReads, 3, 'the recovery cadence replaces stalled authority without waiting for a new incarnation');
  assert.equal(page.timerCount, 1);
  assert.deepEqual(page.rendered.at(-1), [255, 0, 0, 255]);
  assert.equal(page.get('activity').children[0].textContent, 'operator · initial-frame-3');
  page.padButton.handlers.click();
  page.get('pass').handlers.click();
  page.get('text').value = 'unread authority draft';
  page.get('send-text').handlers.click();
  await page.settle();
  assert.equal(page.requests.some(request => request.method === 'POST'), false);
  assert.equal(page.get('text').value, 'unread authority draft');
});


test('opening the handoff picker keeps selection enabled while authority refresh is pending', async () => {
  let hold = false, releaseSeat;
  const page = fixture(request => {
    if (request.url === '/api/v1/play/seat' && hold)
      return new Promise(resolve => { releaseSeat = resolve; });
    return normalReply(request);
  });
  await page.settle();
  const select = page.get('pass-to');
  assert.equal(select.disabled, false);
  hold = true;
  select.disabledChanges = [];
  select.handlers.pointerdown();
  select.handlers.focus();
  assert.equal(select.disabled, false, 'pending refresh cannot cancel the opened native picker');
  assert.equal(select.disabledChanges.includes(true), false, 'refresh never toggles the native picker disabled even transiently');
  assert.equal(page.get('pass').disabled, true, 'the mutation still waits for authority');
  select.value = 'operator';
  releaseSeat(response(seat));
  await page.settle();
  assert.equal(select.value, 'operator');
  assert.equal(page.get('pass').disabled, false);
});

test('a refused disconnect retires a stalled frame seat read so authority polling recovers', async () => {
  let seatReads = 0;
  let heldRequest;
  const page = fixture(request => {
    if (request.url === '/api/v1/play/seat') {
      seatReads += 1;
      if (seatReads === 3) {
        heldRequest = request;
        return new Promise(() => {});
      }
      return response(seat);
    }
    return normalReply(request);
  }, { sessionReply: () => response({ ok: false, message: 'try later' }, 409) });
  await page.settle();
  await page.poll(5000);
  assert.equal(seatReads, 3, 'periodic authority is stalled');
  assert.equal(page.padButton.disabled, true);
  await page.get('leave').handlers.click();
  assert.equal(heldRequest.signal.aborted, true, 'departure cancels the obsolete transport');
  await page.poll(5000);
  assert.equal(seatReads, 4, 'refused departure cannot leave polls behind the retired promise');
  assert.match(page.get('turn').textContent, /내 차례/);
  assert.equal(page.padButton.disabled, false);
  page.padButton.handlers.click();
  await page.settle();
  assert.ok(page.requests.some(request => request.method === 'POST'
    && request.url === '/api/v1/play/pad'), 'fresh authority admits game input again');
});

test('two queued distinct keys survive the first write while its projection read can stall', async () => {
  let completeFirst, holdProjection = false;
  const presses = [];
  const page = fixture(request => {
    if (request.url === '/api/v1/play/seat' && holdProjection) return new Promise(() => {});
    if (request.method === 'POST' && request.url === '/api/v1/dos/press') {
      presses.push(request.body.keys[0]);
      if (presses.length === 1) return new Promise(resolve => {
        completeFirst = () => { holdProjection = true; resolve(response({ ok:true })); };
      });
      return response({ ok:true });
    }
    return normalReply(request);
  });
  await page.settle();
  const keydown = page.get('screen-wrap').handlers.keydown;
  keydown({ key:'a', preventDefault() {} });
  keydown({ key:'b', preventDefault() {} });
  await page.settle();
  assert.deepEqual(presses, ['a'], 'the writes remain serialized');
  completeFirst();
  await page.settle();
  assert.deepEqual(presses, ['a', 'b'], 'the projection read does not drop already-queued input');
  await page.get('leave').handlers.click();
  assert.equal(page.requests.at(-1).url, '/api/v1/play/session', 'disconnect does not wait for projection');
});


test('first no-machine observation retires pending bootstrap authority', async () => {
  let releaseBoot, bootRequest, reads = 0;
  const storage = new Map();
  const page = fixture(request => {
    if (request.url === '/api/v1/play/seat') {
      if (++reads === 1) { bootRequest = request; return new Promise(resolve => { releaseBoot = resolve; }); }
      return response({ ...seat, machine:false, saves_name:null });
    }
    if (request.url === '/api/v1/play/pad') return response(layout);
    return response({ state:'no_machine', activity:[] });
  }, { storage });
  await page.settle();
  assert.equal(bootRequest.signal.aborted, true, 'unobserved-to-absent retires the bootstrap read');
  assert.equal(reads, 2);
  releaseBoot(response(seat));
  await page.settle();
  assert.equal(page.get('send-text').disabled, true);
  assert.equal(page.get('pad').hidden, true);
  assert.equal(storage.get('masc.play.invite'), 'fixture-token');
});

// Like fetch, a stalled request settles only when its signal aborts.
const stall = signal => new Promise((_, reject) =>
  signal.addEventListener('abort', () => reject(signal.reason), { once: true }));

test('changed activity aborts a stalled frame seat read and starts its follow-up', async () => {
  let seatReads = 0, liveReads = 0, stalled;
  const page = fixture(request => {
    if (request.url === '/api/v1/play/seat') {
      seatReads += 1;
      if (seatReads === 3) { stalled = request; return stall(request.signal); }
      return response(seat);
    }
    if (request.url === '/api/v1/play/pad') return response(layout);
    if (request.method === 'POST') return response({ ok: true });
    liveReads += 1;
    return response({ ...frame, change_count: liveReads,
      activity: [{ at: liveReads, who: 'operator', action: 'frame-' + liveReads }] });
  });
  await page.settle();
  await page.poll(5000);
  assert.equal(seatReads, 3, 'periodic authority read is stalled');
  assert.equal(stalled.signal.aborted, false);
  await page.poll(300);
  assert.equal(stalled.signal.aborted, true, 'new activity cancels the stalled authority transport');
  assert.equal(seatReads, 4, 'the follow-up authority read starts without the stalled reply');
});

test('a seat that reports a new program retires the stalled pad read before live does', async () => {
  let program = seat.saves_name, padReads = 0, oldPad;
  const newLayout = { saves_name: 'program-B', buttons: [{ ...layout.buttons[0], label: 'new-layout' }] };
  const page = fixture(request => {
    if (request.url === '/api/v1/play/seat') return response({ ...seat, saves_name: program });
    if (request.url === '/api/v1/play/pad') {
      if (++padReads === 1) { oldPad = request; return stall(request.signal); }
      return response(newLayout);
    }
    // Live keeps reporting incarnation A with unchanged activity.
    return response(frame);
  });
  await page.settle();
  assert.equal(padReads, 1, 'program A layout read is stalled');
  program = 'program-B';
  await page.poll(5000);
  assert.equal(oldPad.signal.aborted, true, 'the seat observation retires the program A layout read');
  assert.equal(padReads, 2, 'program B layout is read while live still reports the old incarnation');
  assert.equal(page.padButton.textContent, 'new-layout');
});

test('a same-program incarnation replacement rereads a settled pad layout', async () => {
  let incarnation = 'machine-A', padReads = 0;
  const page = fixture(request => {
    if (request.url === '/api/v1/play/seat') return response(seat);
    if (request.url === '/api/v1/play/pad') {
      padReads += 1;
      return response(incarnation === 'machine-A' ? layout
        : { ...layout, buttons: [{ ...layout.buttons[0], label: 'new-layout' }] });
    }
    return response({ ...frame, incarnation });
  });
  await page.settle();
  assert.equal(page.padButton.textContent, layout.buttons[0].label, 'program A layout is settled');
  const settledReads = padReads;
  incarnation = 'machine-B';
  await page.poll(300);
  await page.settle();
  assert.equal(padReads, settledReads + 1, 'the replacement machine rereads the same program layout');
  assert.equal(page.padButton.textContent, 'new-layout');
});

test('an incarnation replaced during a refused disconnect keeps stale controls closed', async () => {
  let incarnation = 'machine-A', releaseSession;
  const page = fixture(request => {
    if (request.url === '/api/v1/play/seat') return response(seat);
    if (request.url === '/api/v1/play/pad') return response(layout);
    if (request.method === 'POST') return response({ ok: true });
    return response({ ...frame, incarnation });
  }, { sessionReply: () => new Promise(resolve => { releaseSession = resolve; }) });
  await page.settle();
  assert.equal(page.padButton.disabled, false, 'machine A authority admits input');
  const leaving = page.get('leave').handlers.click();
  await page.settle();
  incarnation = 'machine-B';
  await page.poll(300);
  releaseSession(response({ ok: false, message: 'try later' }, 409));
  await leaving;
  await page.settle();
  assert.equal(page.padButton.disabled, true, 'machine A authority cannot return after the refusal');
  page.padButton.handlers.click();
  await page.settle();
  assert.equal(page.requests.some(r => r.method === 'POST' && r.url === '/api/v1/play/pad'), false);
});
