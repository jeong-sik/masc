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
const seat = { name: 'minsu', machine: true, controller: 'minsu', controller_recoverable: false, saves_name: 'game',
  participants: ['minsu', 'operator'] };
const frame = { state: 'changed', change_count: 3, incarnation: 'machine-1',
  screen: { format: 'rgb8', width: 1, height: 1, rgb_base64: '/wAA' }, activity };
const layout = { saves_name: 'game', buttons: [
  { button: 'BTN_SOUTH', label: '결정', keys: ['return'] },
] };
const response = (json, status = 200) => ({ status, json: async () => json });
const emptyRoom = { messages:[], members:[], has_more:false, presence_seconds:60 };
const roomMessage = (id, text, who = 'keeper-a') => ({ id, text, who, at:1, speaker:'keeper', machine:'dos' });
const gameReply = ({ url }) => response(url === '/api/v1/play/seat' ? seat : url === '/api/v1/play/pad' ? layout : frame);

function fixture(reply, { storage = new Map(), hash = '#fixture-token', roomReply = () => response(emptyRoom) } = {}) {
  const nodes = new Map();
  function element() {
    return { textContent: '', className: '', value: '', hidden: false,
      disabled: false, children: [], dataset: {}, handlers: {},
      addEventListener(name, fn) { this.handlers[name] = fn; },
      append(...nodes) {
        for (const node of nodes) node.parentElement = this;
        this.children.push(...nodes);
      },
      replaceChildren() { this.children = []; },
      get options() { return this.children; },
      getBoundingClientRect() {
        const parent = this.parentElement;
        if (!parent || !parent.rowHeight) return { top:0, bottom:0 };
        const top = parent.getBoundingClientRect().top
          + parent.children.indexOf(this) * parent.rowHeight - parent.scrollTop;
        return { top, bottom:top + parent.rowHeight };
      },
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
        if (selector === '#game-controls button, #game-controls input, #game-controls select') return [padButton, get('text'), get('send-text'), get('pass-to'), get('pass')];
        return [];
      },
    },
    location,
    sessionStorage: { getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key) },
    history: { replaceState(_state, _title, url) { const at = url.indexOf('#'); location.hash = at < 0 ? '' : url.slice(at); } },
    window: { addEventListener(name, handler) { windowHandlers.set(name, handler); } },
    navigator: { getGamepads: () => [] },
    // HTTP LAN origins expose getRandomValues but not secure-context randomUUID.
    crypto: { getRandomValues: values => require('node:crypto').webcrypto.getRandomValues(values) },
    TextEncoder,
    AbortController,
    requestAnimationFrame() {},
    atob,
    performance: { now: () => now },
    setTimeout: fn => timers.push(fn),
    fetch: async (url, init) => {
      const request = { url, authorization: init.headers.Authorization, method: init.method, body: init.body && JSON.parse(init.body) };
      requests.push(request);
      if (url === '/api/v1/play/room') return roomReply(request);
      return reply(request);
    },
  });
  vm.runInContext(script, context);
  const settle = () => new Promise(resolve => setImmediate(resolve));
  return {
    get, padButton, rendered, settle,
    // Existing cases assert game requests; room traffic has its own assertions.
    get requests() { return requests.filter(request => request.url !== '/api/v1/play/room'); },
    get roomRequests() { return requests.filter(request => request.url === '/api/v1/play/room'); },
    async roomPoll() { vm.runInContext('roomNextRead = 0; refreshRoom();', context); await settle(); },
    get reloads() { return reloads; },
    get hash() { return location.hash; },
    navigateFragment(hash) { context.location.hash = hash; windowHandlers.get('hashchange')?.(); },
    restoreFromCache() { windowHandlers.get('pageshow')?.({ persisted: true }); },
    get clears() { return clears; },
    async poll(elapsed = 5000) {
      now += elapsed;
      assert.equal(timers.length, 1, 'the page keeps one next poll');
      await timers.shift()();
      await settle();
    },
  };
}

test('a spectator can speak with several Keepers without moving another controller', async () => {
  const messages = [roomMessage(1, 'ready'), roomMessage(2, 'watching', 'keeper-b')];
  const page = fixture(request => request.url === '/api/v1/play/seat'
    ? response({ ...seat, controller:'operator' }) : gameReply(request), {
    roomReply: ({ body }) => {
      if (body.action === 'say') messages.push(roomMessage(3, body.text, 'minsu'));
      return response({ ...emptyRoom, messages, members:[
        { name:'keeper-a', speaker:'keeper', machine:'dos', seen_at:1 },
        { name:'keeper-b', speaker:'keeper', machine:'msx', seen_at:1 }] });
    }
  });
  await page.settle();
  assert.match(page.get('room-members').textContent, /keeper-a.*keeper-b/);
  assert.equal(page.get('send-text').disabled, true);
  assert.equal(page.get('chat-text').disabled, false);
  page.get('chat-text').value = '같이 볼게요';
  page.get('chat-send').handlers.click();
  await page.settle();
  assert.equal(page.get('chat-text').value, '');
  assert.equal(page.get('room-messages').children.length, 3);
  assert.equal(page.requests.some(request => request.method === 'POST'), false);
});

test('an uncertain public message preserves its exact receipt and draft through reload', async () => {
  const storage = new Map();
  const sends = [];
  const roomReply = ({ body }) => {
    if (body.action === 'say') {
      sends.push(body);
      if (sends.length === 1) throw new Error('acknowledgment lost');
      return response({ ...emptyRoom, messages:[roomMessage(1, body.text, 'minsu')] });
    }
    return response(emptyRoom);
  };
  const first = fixture(gameReply, { storage, roomReply });
  await first.settle();
  first.get('chat-text').value = 'Only once';
  first.get('chat-send').handlers.click();
  await first.settle();
  assert.equal(first.get('chat-text').value, 'Only once');
  assert.match(first.get('room-status').textContent, /확인하지 못/);
  const reloaded = fixture(gameReply, { storage, hash:'', roomReply });
  await reloaded.settle();
  assert.equal(reloaded.get('chat-text').value, 'Only once');
  reloaded.get('chat-send').handlers.click();
  await reloaded.settle();
  assert.deepEqual(sends[1], sends[0]);
  assert.equal(reloaded.get('chat-text').value, '');
  assert.notEqual(first.roomRequests[0].body.client_id, reloaded.roomRequests[0].body.client_id);
});

test('public chat reserves one send while preserving edits made during its acknowledgment', async () => {
  let finish;
  const page = fixture(gameReply, { roomReply: ({ body }) => body.action === 'say'
    ? new Promise(resolve => { finish = () => resolve(response(emptyRoom)); }) : response(emptyRoom) });
  await page.settle();
  page.get('chat-text').value = 'first';
  page.get('chat-send').handlers.click();
  page.get('chat-send').handlers.click();
  await page.settle();
  page.get('chat-text').value = 'second';
  finish();
  await page.settle();
  assert.equal(page.roomRequests.filter(request => request.body.action === 'say').length, 1);
  assert.equal(page.get('chat-text').value, 'second');
});

test('MSX observation uses the same room and never takes the DOS controller', async () => {
  const page = fixture(request => request.url.includes('msx_capture')
    ? response({ state:'no_machine' }) : gameReply(request));
  await page.settle();
  page.get('machine-view').value = 'msx';
  page.get('machine-view').handlers.change();
  await page.poll();
  assert.match(page.get('turn').textContent, /MSX/);
  assert.equal(page.get('game-controls').hidden, true);
  assert.ok(page.requests.some(request => request.url.includes('msx_capture')));
  page.get('chat-text').value = 'MSX에서도 같이';
  page.get('chat-send').handlers.click();
  await page.settle();
  assert.equal(page.roomRequests.find(request => request.body.action === 'say').body.machine, 'msx');
  assert.equal(page.requests.some(request => request.method === 'POST'), false);
});

test('a late DOS frame cannot repaint the selected MSX view', async () => {
  let finish;
  const page = fixture(request => request.url.includes('dos_capture')
    ? new Promise(resolve => { finish = () => resolve(response(frame)); }) : gameReply(request));
  await page.settle();
  page.get('machine-view').value = 'msx';
  page.get('machine-view').handlers.change();
  finish();
  await page.settle();
  assert.deepEqual(page.rendered, []);
  await page.poll();
  assert.equal(page.rendered.length, 1);
});

test('public-room failure does not prevent controller release and disconnect', async () => {
  const storage = new Map();
  let released = false;
  const page = fixture(request => {
    if (request.url === '/api/v1/dos/pass') { released = true; return response({ ok:true }); }
    return gameReply(request);
  }, { storage, roomReply: () => { throw new Error('room unavailable'); } });
  await page.settle();
  await page.get('leave').handlers.click();
  await page.settle();
  assert.equal(released, true);
  assert.equal(storage.get('masc.play.invite'), undefined);
});

test('a silent room leave cannot hold disconnect after controller release', async () => {
  const storage = new Map();
  let release;
  const page = fixture(request => request.url === '/api/v1/dos/pass'
    ? new Promise(resolve => { release = () => resolve(response({ ok:true })); })
    : gameReply(request), {
    storage,
    roomReply: ({ body }) => body.action === 'leave'
      ? new Promise(() => {}) : response(emptyRoom),
  });
  await page.settle();
  let completed = false;
  const disconnected = page.get('leave').handlers.click().then(() => { completed = true; });
  await page.settle();
  assert.equal(storage.get('masc.play.invite'), 'fixture-token');
  assert.equal(completed, false, 'controller release still needs an acknowledgment');
  assert.equal(page.roomRequests.some(request => request.body.action === 'leave'), false);
  release();
  await page.settle();
  const leaves = page.roomRequests.filter(request => request.body.action === 'leave');
  assert.equal(leaves.length, 1);
  assert.equal(leaves[0].authorization, 'Bearer fixture-token');
  assert.equal(completed, true, 'presence cleanup must not hold local disconnect');
  await disconnected;
  assert.equal(storage.get('masc.play.invite'), undefined);
  assert.match(page.get('turn').textContent, /연결을 끊었어요/);
  page.navigateFragment('#fixture-token');
  assert.equal(page.reloads, 1, 'the disconnected tab can reopen its original invitation');
});

test('public chat preserves a Korean IME composition on Enter', async () => {
  const page = fixture(gameReply);
  await page.settle();
  page.get('chat-text').value = '한글';
  page.get('chat-text').handlers.keydown({ key:'Enter', isComposing:true, preventDefault() { throw new Error('composition consumed'); } });
  await page.settle();
  assert.equal(page.roomRequests.some(request => request.body.action === 'say'), false);
});

test('an unsettled game write still permits public conversation without clearing its receipt', async () => {
  const marker = JSON.stringify({ token:'fixture-token', operation:'unconfirmed' });
  const storage = new Map([['masc.play.invite', 'fixture-token'], ['masc.play.pending', marker]]);
  const page = fixture(gameReply, { storage, hash:'' });
  await page.settle();
  assert.equal(page.padButton.disabled, true);
  assert.equal(page.get('chat-text').disabled, false);
  page.get('chat-text').value = '입력 결과를 확인해 주세요';
  page.get('chat-send').handlers.click();
  await page.settle();
  assert.equal(page.roomRequests.find(request => request.body.action === 'say').body.text, '입력 결과를 확인해 주세요');
  assert.equal(page.get('chat-text').value, '');
  assert.equal(storage.get('masc.play.pending'), marker);
  await page.get('leave').handlers.click();
  assert.equal(storage.get('masc.play.invite'), 'fixture-token');
  assert.equal(page.requests.some(request => request.method === 'POST'), false);
});

test('an old room document cannot send or overwrite a replacement invitation draft', async () => {
  const storage = new Map();
  const page = fixture(gameReply, { storage });
  await page.settle();
  const replacement = JSON.stringify({ token:'replacement-token', text:'new draft', pending:null });
  storage.set('masc.play.invite', 'replacement-token');
  storage.set('masc.play.room.draft', replacement);
  page.restoreFromCache();
  page.get('chat-text').value = 'old document';
  page.get('chat-text').handlers.input();
  page.get('chat-send').handlers.click();
  await page.settle();
  await page.get('leave').handlers.click();
  assert.equal(page.reloads, 1);
  assert.equal(page.roomRequests.some(request => request.body.action === 'say'), false);
  assert.equal(storage.get('masc.play.room.draft'), replacement);
  assert.equal(storage.get('masc.play.invite'), 'replacement-token');
  assert.equal(page.get('chat-text').disabled, true);
});

test('a late room acknowledgment and disconnect cannot erase a newer document draft', async () => {
  const storage = new Map();
  let acknowledge;
  const first = fixture(normalReply, { storage, roomReply: ({ body }) => body.action === 'say'
    ? new Promise(resolve => { acknowledge = () => resolve(response(emptyRoom)); }) : response(emptyRoom) });
  await first.settle();
  first.get('chat-text').value = 'first message';
  first.get('chat-send').handlers.click();
  await first.settle();
  const newer = fixture(normalReply, { storage, hash:'' });
  await newer.settle();
  newer.get('chat-text').value = 'newer draft';
  newer.get('chat-text').handlers.input();
  const saved = storage.get('masc.play.room.draft');
  acknowledge();
  await first.settle();
  await first.get('leave').handlers.click();
  assert.equal(storage.get('masc.play.room.draft'), saved);
  assert.equal(storage.get('masc.play.invite'), 'fixture-token');
  assert.equal(first.requests.some(request => request.method === 'POST'), false);
  assert.match(first.get('room-status').textContent, /새로고침/);
  await newer.get('leave').handlers.click();
  assert.equal(storage.size, 0, 'the current document may explicitly clear its own draft on disconnect');
});

test('a queued public message cannot dispatch after a newer document replaces its draft', async () => {
  const storage = new Map();
  let finishRead;
  const older = fixture(gameReply, { storage, roomReply: ({ body }) => body.action === 'read'
    ? new Promise(resolve => { finishRead = () => resolve(response(emptyRoom)); }) : response(emptyRoom) });
  await older.settle();
  older.get('chat-text').value = 'superseded queued public message';
  older.get('chat-send').handlers.click();
  await older.settle();
  assert.equal(older.roomRequests.some(request => request.body.action === 'say'), false,
    'the message is waiting behind the admitted read');

  const newer = fixture(gameReply, { storage, hash:'' });
  await newer.settle();
  newer.get('chat-text').value = 'newer draft';
  newer.get('chat-text').handlers.input();
  const saved = storage.get('masc.play.room.draft');
  finishRead();
  await older.settle();
  assert.equal(older.roomRequests.some(request => request.body.action === 'say'), false,
    'superseded draft authority must be checked before the public POST');
  assert.equal(storage.get('masc.play.room.draft'), saved);
  assert.equal(storage.get('masc.play.invite'), 'fixture-token');
  assert.equal(older.get('chat-text').disabled, true);
  assert.match(older.get('room-status').textContent, /새로고침/);
  assert.equal(newer.get('chat-text').value, 'newer draft');
  assert.equal(newer.get('chat-text').disabled, false);
});

test('a queued public message still dispatches when its own document edits the next draft', async () => {
  const storage = new Map();
  let finishRead;
  const page = fixture(gameReply, { storage, roomReply: ({ body }) => body.action === 'read'
    ? new Promise(resolve => { finishRead = () => resolve(response(emptyRoom)); }) : response(emptyRoom) });
  await page.settle();
  page.get('chat-text').value = 'admitted message';
  page.get('chat-send').handlers.click();
  await page.settle();
  page.get('chat-text').value = 'next draft';
  page.get('chat-text').handlers.input();
  finishRead();
  await page.settle();
  const sends = page.roomRequests.filter(request => request.body.action === 'say');
  assert.equal(sends.length, 1);
  assert.equal(sends[0].body.text, 'admitted message');
  assert.equal(page.get('chat-text').value, 'next draft');
  assert.equal(JSON.parse(storage.get('masc.play.room.draft')).text, 'next draft');
  assert.equal(page.get('chat-text').disabled, false);
});

function roomViewport(page) {
  const list = page.get('room-messages');
  list.rowHeight = 20;
  list.clientHeight = 60;
  list.scrollTop = 0;
  list.getBoundingClientRect = () => ({ top:100, bottom:160 });
  Object.defineProperty(list, 'scrollHeight', { get:() => list.children.length * list.rowHeight });
  return list;
}

test('room history keeps a visible message and pixel offset across rolling retention', async () => {
  let messages = Array.from({ length:100 }, (_, index) => roomMessage(index + 1, 'message ' + (index + 1)));
  const page = fixture(gameReply, { roomReply: () => response({ ...emptyRoom, messages }) });
  const list = roomViewport(page);
  await page.settle();
  list.scrollTop = 39 * list.rowHeight + 7; // Read message 40, seven pixels into its row.
  messages = messages.slice(1).concat(roomMessage(101, 'message 101'));
  await page.roomPoll();
  assert.equal(list.scrollTop, 38 * list.rowHeight + 7,
    'dropping an earlier message must not move the visible message or within-row offset');
  messages = Array.from({ length:100 }, (_, index) => roomMessage(index + 50, 'message ' + (index + 50)));
  await page.roomPoll();
  assert.equal(list.scrollTop, 0, 'an evicted anchor clamps to the oldest surviving message');
  assert.equal(list.children[0].children[1].textContent, 'message 50');
});

test('room history keeps following new messages when already at the bottom', async () => {
  let messages = Array.from({ length:10 }, (_, index) => roomMessage(index + 1, 'message ' + (index + 1)));
  const page = fixture(gameReply, { roomReply: () => response({ ...emptyRoom, messages }) });
  const list = roomViewport(page);
  await page.settle();
  list.scrollTop = list.scrollHeight - list.clientHeight;
  messages = messages.concat(roomMessage(11, 'message 11'));
  await page.roomPoll();
  assert.equal(list.scrollTop, list.scrollHeight);
  assert.equal(list.children.at(-1).children[1].textContent, 'message 11');
});

test('game input works on an HTTP origin without crypto.randomUUID', async () => {
  const storage = new Map();
  let acknowledge;
  const page = fixture(request => request.method === 'POST'
    ? new Promise(resolve => { acknowledge = () => resolve(response({ ok:true })); })
    : normalReply(request), { storage });
  await page.settle();
  page.padButton.handlers.click();
  await page.settle();
  assert.equal(page.requests.filter(request => request.method === 'POST').length, 1);
  const marker = JSON.parse(storage.get('masc.play.pending'));
  assert.equal(marker.token, 'fixture-token');
  assert.match(marker.operation, /^[a-f0-9]{32}$/);
  acknowledge();
  await page.settle();
  assert.equal(storage.has('masc.play.pending'), false);
});

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
  assert.equal(seatReads, 2);
  assert.equal(page.padButton.disabled, true);
  await page.poll();
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
  const page = fixture(request => request.method === 'POST'
    ? new Promise(resolve => { release = () => resolve(response({ ok: true })); })
    : normalReply(request), { storage });
  await page.settle();
  const disconnected = page.get('leave').handlers.click();
  await page.settle();
  assert.equal(page.get('leave').disabled, true);
  assert.equal(storage.get('masc.play.invite'), 'fixture-token');
  assert.deepEqual(page.requests.filter(request => request.method === 'POST'), [{
    url: '/api/v1/dos/pass', authorization: 'Bearer fixture-token', method: 'POST', body: {},
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
  assert.equal(page.requests.some(request => request.method === 'POST'), false);
  assert.equal(storage.size, 0);
});

for (const [name, release] of [
  ['refused', () => response({ ok: false }, 409)],
  ['unknown', () => { throw new Error('connection lost after release'); }],
]) {
  test(`a ${name} disconnect retains its credential across reload for recovery`, async () => {
    const storage = new Map();
    const page = fixture(request => request.method === 'POST' ? release() : normalReply(request), { storage });
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
    assert.equal(recovered.requests.some(request => request.method === 'POST'), false);
    assert.equal(storage.size, name === 'unknown' ? 2 : 0);
    if (name === 'unknown') {
      assert.match(recovered.get('status').textContent, /운영자에게 초대 회수/);
      assert.equal(recovered.padButton.disabled, true);
    }
  });
}

test('disconnect keeps the credential when its current seat cannot be read', async () => {
  const storage = new Map();
  let failSeat = false;
  const page = fixture(request => failSeat && request.url === '/api/v1/play/seat'
    ? response({}, 503) : normalReply(request), { storage });
  await page.settle();
  failSeat = true;
  await page.get('leave').handlers.click();
  assert.equal(storage.get('masc.play.invite'), 'fixture-token');
  assert.equal(page.requests.some(request => request.method === 'POST'), false);
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
    if (request.method === 'POST' && request.url === '/api/v1/dos/pass') {
      return new Promise(resolve => { finishRelease = () => { holder = null; resolve(response({ ok: true })); }; });
    }
    return normalReply(request);
  }, { storage });
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
    ['/api/v1/dos/type', '/api/v1/dos/pass']);
  assert.equal(storage.get('masc.play.invite'), 'fixture-token');
  finishRelease();
  await disconnected;
  assert.equal(holder, null);
  assert.equal(storage.size, 0);
});

test('disconnect uses its owned-seat receipt when a stale live response says no machine', async () => {
  const storage = new Map();
  let defer = false, completeSeat, completeLive;
  const page = fixture(request => {
    if (defer && request.method === 'GET' && request.url === '/api/v1/play/seat') {
      return new Promise(resolve => { completeSeat = resolve; });
    }
    if (defer && request.url.startsWith('/api/v1/lane-addons/live')) {
      return new Promise(resolve => { completeLive = resolve; });
    }
    return normalReply(request);
  }, { storage });
  await page.settle();
  defer = true;
  const poll = page.poll();
  const disconnected = page.get('leave').handlers.click();
  await page.settle();
  // These responses resume in adjacent microtasks: the fresh seat applies,
  // then the old live poll resets shared machine state before disconnect runs.
  defer = false;
  completeSeat(response(seat));
  completeLive(response({ state: 'no_machine', activity }));
  await Promise.all([poll, disconnected]);
  assert.deepEqual(page.requests.filter(request => request.method === 'POST').map(request => ({
    url: request.url, body: request.body,
  })), [{ url: '/api/v1/dos/pass', body: {} }]);
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
    ['/api/v1/dos/pass']);
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
  const page = fixture(request => {
    if (request.method === 'POST') throw new Error('release acknowledgement lost');
    return normalReply(request);
  }, { storage });
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

test('new machine activity and target selection refresh seats within the idle scan interval', async () => {
  let currentActivity = activity;
  const page = fixture(request => request.url === '/api/v1/play/seat'
    ? response({ ...seat, controller:'operator' })
    : request.url.includes('/lane-addons/live') ? response({ ...frame, activity:currentActivity }) : normalReply(request));
  await page.settle();
  const seats = () => page.requests.filter(request => request.url === '/api/v1/play/seat').length;
  const initial = seats();
  currentActivity = [{ at:2, who:'operator', action:'pass minsu' }];
  await page.poll(300);
  assert.equal(seats(), initial + 1, 'new machine activity immediately refreshes authority');
  await page.poll(300);
  assert.equal(seats(), initial + 1, 'an unchanged activity does not bypass the scan interval');
  page.get('pass-to').handlers.focus();
  await page.settle();
  assert.equal(seats(), initial + 2, 'target selection also refreshes immediately');
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
