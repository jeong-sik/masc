const assert = require('node:assert/strict');
const vm = require('node:vm');
const test = require('node:test');
// The production drain, unchanged. The rules are small here so the cuts show;
// production declares them from Browser_ego_page_events before this text.
const pageEvents = require('./browser_ego_page_events_source.cjs');
const rules = {requests: 3, pathBytes: 12, headerNames: 2, egoBuffer: 6, redacted: 'REDACTED'};
// The SDK process has Node's URL; a vm context does not.
const load = () => vm.runInNewContext(pageEvents(rules) + '\n({mascPageEvents, mascNetworkLog})', {URL});
// Values from another vm realm compare only through JSON.
const plain = value => JSON.parse(JSON.stringify(value));
const secret = 'L8_TEST_SECRET';
const page = (label, batches) => ({label, async events() { return batches.shift() ?? []; }});
const start = (id, url, extra = {}) => ({method: 'Network.requestWillBeSent', sessionId: 'S', params: {requestId: id,
  request: {url, method: 'GET', headers: {Cookie: secret, Authorization: secret, Accept: 'x'}}, wallTime: 1794029520.5, ...extra}});
const response = (id, status = 200) => ({method: 'Network.responseReceived', params: {requestId: id,
  response: {status, mimeType: 'text/plain', headers: {'Set-Cookie': secret}, url: 'ignored'}}});
const finished = id => ({method: 'Network.loadingFinished', params: {requestId: id, encodedDataLength: 194.0}});

test('a network read keeps no header value, cookie or query value and keeps the other events', async () => {
  const {mascPageEvents, mascNetworkLog} = load();
  const loaded = {method: 'Page.loadEventFired', params: {timestamp: 1}};
  const p1 = page('p1', [[start('1', 'https://user:pw@a.test/x?token=' + secret + '&flag#frag'), loaded,
    {method: 'Network.requestWillBeSentExtraInfo', params: {requestId: '1', associatedCookies: [{cookie: {value: secret}}]}},
    response('1'), finished('1')]]);
  const log = plain(await mascNetworkLog(p1));
  assert.equal(JSON.stringify(log).includes(secret), false);
  assert.equal(JSON.stringify(log).includes('user'), false);
  assert.deepEqual(log, {requests: [{method: 'GET', url: 'https://a.test/x?token=REDACTED&flag', urlCut: false, timestamp: 1794029520500,
    requestHeaders: {names: ['Cookie', 'Authorization'], total: 3}, state: 'completed', status: 200, mimeType: 'text/plain',
    bytesReceived: 194, responseHeaders: {names: ['Set-Cookie'], total: 1}}],
    dropped: 0, malformedEvents: {count: 0, last: null}, fullBufferReads: 0});
  // The read kept the page event for the next workflow drain, and only once.
  assert.deepEqual(plain(await mascPageEvents(p1)), [loaded]);
  assert.deepEqual(plain(await mascPageEvents(p1)), []);
});

test('a workflow drain hands Network events to the log, not to the caller', async () => {
  const {mascPageEvents, mascNetworkLog} = load();
  const p1 = page('p1', [[start('1', 'https://a.test/'), {method: 'Runtime.bindingCalled', params: {name: 'b'}}]]);
  assert.deepEqual(plain(await mascPageEvents(p1)).map(event => event.method), ['Runtime.bindingCalled']);
  assert.deepEqual(plain(await mascNetworkLog(p1)).requests.map(row => row.state), ['pending']);
  // Labels keep apart.
  assert.deepEqual(plain(await mascNetworkLog(page('p2', []))).requests, []);
});

test('redirects, responses without a finished body, failures and blocks have their own state', async () => {
  const {mascNetworkLog} = load();
  const p1 = page('p1', [[start('r', 'https://a.test/redir'),
    start('r', 'https://a.test/x', {redirectResponse: {status: 302, mimeType: '', headers: {Location: '/x'}, encodedDataLength: 171}}),
    response('r'),
    start('f', 'https://a.test/f'), {method: 'Network.loadingFailed', params: {requestId: 'f', errorText: 'net::ERR_CONNECTION_REFUSED'}},
    start('b', 'https://b.test/b'), {method: 'Network.loadingFailed', params: {requestId: 'b', errorText: '', blockedReason: 'inspector'}}]]);
  const rows = plain(await mascNetworkLog(p1)).requests;
  assert.deepEqual(rows.map(row => [row.url, row.state, row.status ?? row.error ?? null]),
    [['https://a.test/x', 'responded', 200], ['https://a.test/f', 'failed', 'net::ERR_CONNECTION_REFUSED'], ['https://b.test/b', 'failed', 'blocked: inspector']]);
});

test('the log keeps the newest requests, and an end whose start is gone is skipped', async () => {
  const {mascNetworkLog} = load();
  const p1 = page('p1', [[start('1', 'https://a.test/1'), start('2', 'https://a.test/2'), start('3', 'https://a.test/3'), start('4', 'https://a.test/4'),
    response('1'), finished('1'), response('9'), finished('9')]]);
  const log = plain(await mascNetworkLog(p1));
  assert.deepEqual(log.requests.map(row => row.url), ['https://a.test/2', 'https://a.test/3', 'https://a.test/4']);
  assert.equal(log.dropped, 1);
  assert.deepEqual(log.malformedEvents, {count: 0, last: null});
});

test('addresses keep a scheme only, or a cut path that never ends inside an escape', async () => {
  const {mascNetworkLog} = load();
  const p1 = page('p1', [[start('1', 'data:text/plain,' + secret), start('2', 'https://a.test/abcdefghij%E2%82%AC?q=' + secret),
    start('3', 'blob:https://a.test/0f0f')]]);
  const rows = plain(await mascNetworkLog(p1)).requests;
  assert.deepEqual(rows.map(row => [row.url, row.urlCut]), [['data:', true], ['https://a.test/abcdefghij?q=REDACTED', true], ['blob:', true]]);
});

test('malformed Network events are counted, a full buffer is counted, and the kept rest stays bounded', async () => {
  const {mascPageEvents, mascNetworkLog} = load();
  const noWall = start('1', 'https://a.test/');
  delete noWall.params.wallTime;
  const other = index => ({method: 'Page.frameStartedLoading', params: {index}});
  const p1 = page('p1', [[noWall, other(1), other(2), other(3), other(4), other(5)], [other(6), other(7)]]);
  const log = plain(await mascNetworkLog(p1));
  assert.deepEqual(log.requests, []);
  assert.deepEqual(log.malformedEvents, {count: 1, last: 'Network.requestWillBeSent: no address, method or wallTime'});
  assert.equal(log.fullBufferReads, 1);
  assert.deepEqual(plain(await mascPageEvents(p1)).map(event => event.params.index), [2, 3, 4, 5, 6, 7]);
});

test('a Page with no label or an event buffer that is not a list fails the drain', async () => {
  const {mascPageEvents, mascNetworkLog} = load();
  await assert.rejects(mascPageEvents({async events() { return []; }}), /ego Page has no label/);
  await assert.rejects(mascNetworkLog({label: 'p1', async events() { return null; }}), /ego returned a non-array event buffer/);
});
