const assert = require('node:assert/strict');
const vm = require('node:vm');
const test = require('node:test');
// The production drain and console read, unchanged. The rules are small here
// so the cuts show; production declares them from OCaml before this text.
const pageEvents = require('./browser_ego_page_events_source.cjs');
const consoleRead = require('./browser_ego_console_source.cjs');
const drainRules = {requests: 3, pathBytes: 12, headerNames: 2, egoBuffer: 50, redacted: 'REDACTED'};
const load = (rules = {entries: 3, textBytes: 10, answerUnits: 100000}) =>
  vm.runInNewContext(pageEvents(drainRules) + '\n' + consoleRead(rules) + '\n({mascConsoleRead, mascPageEvents, mascNetworkLog})',
    {URL, TextEncoder, TextDecoder});
// Values from another vm realm compare only through JSON.
const plain = value => JSON.parse(JSON.stringify(value));
const reason = error => String(error && error.message || error);
const line = (text, timestamp = 1794035766700.5) => ({method: 'Runtime.consoleAPICalled', params: {type: 'log',
  args: [{type: 'string', value: text}], executionContextId: 1, timestamp}});
// An ego Page as L9 measured it: with the hiding on no console event comes
// out, and Runtime.enable replays the stored entries only when Runtime was off.
// A late replay reaches the buffer only with the next command.
const fakePage = ({stored = [], runtime = false, fail = {}, late = false} = {}) => {
  const page = {label: 'p1', calls: [], buffer: [], hidden: true, runtime, stored};
  let inFlight = [];
  page.events = async () => page.buffer.splice(0);
  page.cdp = async method => {
    page.calls.push(method);
    page.buffer.push(...inFlight.splice(0));
    if (fail[method]) throw new Error(method + ' failed');
    if (method === 'egoAutomated.disable') page.hidden = false;
    else if (method === 'egoAutomated.enable') page.hidden = true;
    else if (method === 'Runtime.disable') page.runtime = false;
    else if (method === 'Runtime.enable' && !page.runtime) {
      page.runtime = true;
      page.buffer.push({method: 'Runtime.executionContextCreated', params: {context: {id: 1}}});
      if (!page.hidden) (late ? inFlight : page.buffer).push(...page.stored);
    }
    return {};
  };
  return page;
};

test('a read replays the stored entries between turning the hiding off and on, and leaves the other events', async () => {
  const {mascConsoleRead, mascPageEvents} = load();
  const loaded = {method: 'Page.loadEventFired', params: {timestamp: 1}};
  const page = fakePage({stored: [line('first'), line('second')], runtime: true});
  page.buffer.push(loaded);
  const answer = plain(await mascConsoleRead(page, reason));
  assert.deepEqual(page.calls, ['egoAutomated.disable', 'Runtime.disable', 'Runtime.enable', 'egoAutomated.enable']);
  assert.equal(answer.ok, true);
  assert.deepEqual(answer.value.entries, [
    {type: 'console', level: 'log', text: 'first', textCut: false, timestamp: 1794035766700},
    {type: 'console', level: 'log', text: 'second', textCut: false, timestamp: 1794035766700}]);
  assert.equal(answer.value.hiding.restored, true);
  assert.equal(Number.isInteger(answer.value.hiding.offMs), true);
  assert.equal(page.hidden, true);
  // The replay's own Runtime events went to the read; the page event stays.
  assert.deepEqual(plain(await mascPageEvents(page)), [loaded]);
});

test('a read also takes the replay that arrives while the hiding is turned back on', async () => {
  const {mascConsoleRead} = load();
  const page = fakePage({stored: [line('late')], late: true});
  const {value} = plain(await mascConsoleRead(page, reason));
  assert.deepEqual(value.entries.map(entry => entry.text), ['late']);
});

test('a read keeps the newest entries and cuts a text where a character starts', async () => {
  const {mascConsoleRead} = load();
  const page = fakePage({stored: [line('a'), line('b'), line('c'), line('d'), line('가가가가')]});
  const {value} = plain(await mascConsoleRead(page, reason));
  assert.deepEqual(value.entries.map(entry => [entry.text, entry.textCut]), [['c', false], ['d', false], ['가가가', true]]);
  assert.equal(value.dropped, 2);
});

test('a read keeps its answer within the JSON budget', async () => {
  const {mascConsoleRead} = load({entries: 10, textBytes: 40, answerUnits: 450});
  const control = '\u0001'.repeat(40);
  const page = fakePage({stored: [line(control), line(control), line(control), line('last')]});
  const {value} = plain(await mascConsoleRead(page, reason));
  assert.deepEqual(value.entries.map(entry => entry.text.length), [40, 4]);
  assert.equal(value.dropped, 2);
});

test('arguments and uncaught errors become text as CDP describes them, and malformed events are counted', async () => {
  const {mascConsoleRead} = load({entries: 10, textBytes: 200, answerUnits: 100000});
  const args = [{type: 'string', value: 'args'}, {type: 'number', value: 5, description: '5'}, {type: 'undefined'},
    {type: 'object', subtype: 'null', value: null}, {type: 'bigint', unserializableValue: '5n', description: '5n'},
    {type: 'object', className: 'Object', description: 'Object', objectId: '1'}];
  const page = fakePage({stored: [
    {method: 'Runtime.consoleAPICalled', params: {type: 'warning', args, timestamp: 2}},
    {method: 'Runtime.exceptionThrown', params: {timestamp: 3, exceptionDetails: {text: 'Uncaught', exception: {type: 'object', description: 'Error: boom'}}}},
    {method: 'Runtime.exceptionThrown', params: {timestamp: 4, exceptionDetails: {text: 'Uncaught', exception: {type: 'string', value: 'thrown'}}}},
    {method: 'Runtime.consoleAPICalled', params: {type: 'log', args: [{value: 1}], timestamp: 5}},
    {method: 'Runtime.consoleAPICalled', params: {type: 'log', args: []}}]});
  const {value} = plain(await mascConsoleRead(page, reason));
  assert.deepEqual(value.entries.map(entry => [entry.type, entry.level, entry.text]), [
    ['console', 'warning', 'args 5 undefined null 5n Object'],
    ['javascript', 'error', 'Uncaught Error: boom'],
    ['javascript', 'error', 'Uncaught thrown']]);
  assert.deepEqual(value.malformedEvents, {count: 2, last: 'Runtime.consoleAPICalled: no timestamp'});
});

test('a failure says whether the hiding came back on', async () => {
  const {mascConsoleRead} = load();
  const refused = fakePage({fail: {'egoAutomated.disable': true}});
  assert.deepEqual(plain(await mascConsoleRead(refused, reason)),
    {ok: false, before: true, error: "ego's console hiding was not turned off: egoAutomated.disable failed"});
  assert.deepEqual(refused.calls, ['egoAutomated.disable']);
  const restored = fakePage({fail: {'Runtime.enable': true}});
  const answer = plain(await mascConsoleRead(restored, reason));
  assert.equal(answer.before, true);
  assert.match(answer.error, /Runtime\.enable failed; ego's console hiding was off for \d+ ms and is on again/);
  assert.equal(restored.hidden, true);
  const leftOff = fakePage({fail: {'Runtime.enable': true, 'egoAutomated.enable': true}});
  assert.deepEqual(plain(await mascConsoleRead(leftOff, reason)), {ok: false,
    error: "the tab's console was not read: Runtime.enable failed; ego's console hiding was not turned back on: egoAutomated.enable failed"});
  const readLeftOff = fakePage({stored: [line('kept')], fail: {'egoAutomated.enable': true}});
  const {value} = plain(await mascConsoleRead(readLeftOff, reason));
  assert.deepEqual(value.entries.map(entry => entry.text), ['kept']);
  assert.deepEqual({restored: value.hiding.restored, error: value.hiding.error}, {restored: false, error: 'egoAutomated.enable failed'});
});

test('network events that arrive during the read still reach the network log', async () => {
  const {mascConsoleRead, mascNetworkLog} = load();
  const page = fakePage({stored: [line('only')]});
  page.stored.push({method: 'Network.requestWillBeSent', params: {requestId: '1', wallTime: 1794035766.7,
    request: {url: 'https://a.test/x?token=secret', method: 'GET', headers: {}}}});
  await mascConsoleRead(page, reason);
  assert.deepEqual(plain(await mascNetworkLog(page)).requests.map(row => row.url), ['https://a.test/x?token=REDACTED']);
});
