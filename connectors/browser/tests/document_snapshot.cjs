const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {webcrypto} = require('node:crypto');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '../../..');
const extension = readFileSync(path.join(root, 'connectors/browser/extension/background.js'), 'utf8');
const scene = readFileSync(path.join(root, 'lib/browser_scene_script.ml'), 'utf8')
  .split('let runtime = {js|')[1].split('|js}')[0];
const snapshot = readFileSync(path.join(root, 'lib/browser_lane/browser_document.ml'), 'utf8')
  .split('let runtime = {js|')[1].split('|js}')[0];
assert.ok(extension.startsWith(scene + '\n'), 'existing scene code remains identical');
assert.ok(extension.includes(snapshot), 'document source code is identical in both backends');
const html = '<html><head><meta name="masc-revision" content="B"></head><body>Actual document</body></html>';
const document = {title:'Existing document', documentElement:{outerHTML:html}};
const window = {};
window.top = window;
const page = vm.createContext({document, window, location:{href:'http://example.test:8123/app?q=1#section'},
  innerWidth:800, innerHeight:600, scrollX:12, scrollY:45, crypto:webcrypto, TextEncoder, Date});
const calls = [];
const listener = {addListener() {}};
const background = vm.createContext({console, TextEncoder, setTimeout() {}, clearTimeout() {},
  browser:{runtime:{connectNative:() => ({onMessage:listener,onDisconnect:listener})},
    tabs:{executeScript:async (tab, args) => {
      calls.push({tab,args});
      return [vm.runInContext(args.code, page)];
    }, query:async () => {throw new Error('observer must use its existing explicit tab');}}}});
vm.runInContext(extension, background);

(async () => {
  const first = await vm.runInContext('pageRead({tabId:4,includeHtml:true})', background);
  const second = await vm.runInContext('pageRead({tabId:4,includeHtml:true})', background);
  assert.equal(first.tabId, 4);
  assert.equal(first.url, page.location.href);
  assert.equal(first.html, html);
  assert.equal(first.htmlComplete, true);
  assert.equal(first.htmlUnavailableReason, null);
  assert.equal(first.documentId, second.documentId);
  assert.match(first.documentId, /^[a-f0-9]{32}$/);
  assert.equal(document.documentElement.outerHTML, html, 'read does not edit DOM');
  assert.equal(page.scrollX, 12);
  assert.equal(page.scrollY, 45);
  assert.equal(calls.length, 2);
  assert.ok(calls.every(c => c.tab === 4 && c.args.runAt === 'document_end'));
  document.documentElement = {outerHTML:'<html><body>New root</body></html>'};
  const next = await vm.runInContext('pageRead({tabId:4,includeHtml:true})', background);
  assert.notEqual(next.documentId, first.documentId, 'new root changes document identity');
  document.documentElement.outerHTML = '<html>' + 'x'.repeat(1024 * 1024) + '</html>';
  const large = await vm.runInContext('pageRead({tabId:4,includeHtml:true})', background);
  assert.equal(large.html, null, 'oversized HTML never becomes a truncated confirmed document');
  assert.equal(large.htmlComplete, false);
  assert.equal(large.htmlUnavailableReason, 'document_html_exceeds_1_mib');
  assert.equal(large.documentId, next.documentId);
  assert.equal(large.url, page.location.href);
  window.top = {};
  await assert.rejects(() => vm.runInContext('pageRead({tabId:4,includeHtml:true})', background),
    /document_observation_requires_top_document/);
  console.log('same-document source capture: identity, exact URL, no focus or DOM edits, oversize and frame refusal passed');
})().catch(error => {console.error(error); process.exitCode = 1;});
