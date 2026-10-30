import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../connectors/browser/extension/background.js', import.meta.url), 'utf8');
let captureCalls = [];
let replies = [];
let closed = false;
let navigated = false;
let oversized = false;
let queried = 0;
let changedViewport = false;
const browser = {
  runtime: {getBrowserInfo: async () => ({name: "Firefox", version: "155.0.1", zen: {version: "1.22b"}}), connectNative: () => ({
    onMessage: {addListener() {}}, onDisconnect: {addListener() {}},
    postMessage: value => replies.push(value),
  })},
  tabs: {
    query: async () => {queried++; return [{id: 99}];},
    get: async id => {
      assert.equal(id, 7);
      if (closed) throw new Error('Invalid tab ID');
      return {url: navigated && captureCalls.length ? 'https://example.org/after' : 'https://example.org/before', title: 'Fixture'};
    },
    executeScript: async (id, options) => {
      assert.equal(options.runAt, "document_end");
      assert.equal(id, 7);
      return [{documentId:'fixture',width:800,height:600,scrollX:0,scrollY:changedViewport && captureCalls.length ? 120 : 0}];
    },
    captureTab: async (id, options) => {
      captureCalls.push({id, options});
      return 'data:image/png;base64,' + (oversized ? 'A'.repeat(8 * 1024 * 1024) : 'iVBORw0KGgo=');
    },
  },
};
const context = vm.createContext({browser, TextEncoder, setTimeout, clearTimeout});
vm.runInContext(source, context);
async function command(args) {
  context.command = {id: 'capture-fixture', verb: 'page.capture', args};
  await vm.runInContext('onHostMessage(command)', context);
  return replies.at(-1);
}
assert.equal((await command({})).ok, false);
assert.equal(queried, 0, 'missing target must not query the active tab');
const good = await command({tabId: 7});
assert.equal(good.ok, true);
assert.equal(good.data.tabId, 7);
assert.equal(good.data.mimeType, 'image/png');
assert.equal(good.data.data, 'iVBORw0KGgo=');
assert.equal(captureCalls[0].id, 7);
assert.equal(captureCalls[0].options.format, 'png');
closed = true;
assert.equal((await command({tabId: 7})).ok, false);
assert.equal(captureCalls.length, 1, 'closed target must not capture another tab');
closed = false; navigated = true; captureCalls = [];
assert.equal((await command({tabId: 7})).error, 'viewport_changed_during_capture');
navigated = false; oversized = true;
const large = await command({tabId: 7});
assert.equal(large.ok, false);
assert.equal(large.error, 'browser_reply_exceeds_8_mib');
assert.equal('data' in large, false);
oversized = false;
assert.equal((await command({tabId: 7})).ok, true, 'oversized capture must not disconnect the lane');
console.log('PASS: explicit target, PNG, closed tab, navigation race, frame bound, recovery');

context.command = {id: 'metadata-fixture', verb: 'browser.info', args: {}};
await vm.runInContext('onHostMessage(command)', context);
assert.equal(replies.at(-1).data.zen.version, '1.22b');
assert.equal(replies.at(-1).data.version, '155.0.1');
console.log('PASS: actual browser info is forwarded including explicit Zen metadata');

changedViewport = true; captureCalls = [];
assert.equal((await command({tabId:7})).error, 'viewport_changed_during_capture');
console.log('PASS: scrolling during capture rejects mismatched screenshot geometry');
