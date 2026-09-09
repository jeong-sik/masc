const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {webcrypto} = require('node:crypto');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const source = readFileSync(path.join(root, 'lib/browser_scene_script.ml'), 'utf8')
  .split('let runtime = {js|')[1].split('|js}')[0];
assert.ok(readFileSync(path.join(root, 'connectors/browser/extension/background.js'), 'utf8')
  .startsWith(source + '\n'), 'driver and extension must execute identical scene code');
const limit = 1024 * 1024;
const rect = {x:0, y:0, width:10, height:10, right:10, bottom:10};

function fixture() {
  const document = {title:'ordinary HTTP page', documentElement:{}, body:{childNodes:[]}};
  const style = {display:'block', visibility:'visible', opacity:'1', color:'rgb(0, 0, 0)',
    fontSize:'16px', fontWeight:'400', whiteSpace:'normal'};
  const link = {nodeType:1, localName:'a', innerText:'A', parentElement:null,
    isConnected:true, ownerDocument:document, childNodes:[],
    hasAttribute:name => name === 'href', getAttribute:() => null, matches:selector => selector !== ':disabled',
    getClientRects:() => [rect], click:() => {}};
  link.href='http://example.test/observed';
  document.body.childNodes.push(link);
  const context = vm.createContext({document, window:{},
    location:{href:'http://example.test/path?identity=exact#fragment'},
    innerWidth:800, innerHeight:600, scrollX:0, scrollY:0,
    getComputedStyle:() => style, HTMLInputElement:class {}, HTMLTextAreaElement:class {},
    // Model insecure-context WebCrypto: getRandomValues exists, randomUUID does not.
    crypto:{getRandomValues:array => webcrypto.getRandomValues(array)}, TextEncoder});
  vm.runInContext(source, context);
  return {document, style, link, context,
    read:() => vm.runInContext("browserScene({mode:'read',maxChars:1})", context)};
}

const normal = fixture();
const first = normal.read();
assert.match(first.documentId, /^[a-f0-9]{32}$/);
assert.equal(normal.read().documentId, first.documentId, 'repeat read preserves document identity');
assert.equal(first.url, normal.context.location.href, 'complete URL identity survives');
assert.equal(first.nodes.length, 1);
assert.equal(first.nodes[0].href, 'http://example.test/observed');
assert.ok(Buffer.byteLength(JSON.stringify(first), 'utf8') <= limit);
const oldId = first.documentId;
normal.document.documentElement = {};
assert.notEqual(normal.read().documentId, oldId, 'new document gets fresh random identity');

// A recycled anchor remains the same DOM object, but not the same observation.
const recycled = fixture();
const observed = recycled.read();
recycled.context.reference = {mode:'resolve_link',documentId:observed.documentId,nodeId:observed.nodes[0].nodeId};
assert.equal(vm.runInContext('browserScene(reference)',recycled.context),recycled.link);
recycled.link.href='http://example.test/recycled';
assert.throws(() => vm.runInContext('browserScene(reference)',recycled.context), /scene_link_destination_changed/);
const reread=recycled.read();
assert.notEqual(reread.nodes[0].nodeId,observed.nodes[0].nodeId);
assert.throws(() => vm.runInContext('browserScene(reference)',recycled.context), /scene_link_destination_changed/,
  'a newer read must not overwrite the old reference destination');
recycled.context.reference.nodeId=reread.nodes[0].nodeId;
assert.equal(vm.runInContext('browserScene(reference)',recycled.context),recycled.link);

for (const [name, alter] of [
  ['UTF-8 title', f => { f.document.title = '🙂'.repeat(300000); }],
  ['JSON escaping', f => { f.document.title = '"'.repeat(600000); }],
  ['observed href', f => { f.link.href = 'http://example.test/' + 'x'.repeat(9 * limit); }],
  ['complete URL', f => { f.context.location.href = 'http://example.test/' + 'x'.repeat(9 * limit); }],
  ['node style metadata', f => { f.style.fontWeight = 'x'.repeat(2 * limit); }],
  ['rectangle arrays', f => { f.link.getClientRects = () => Array(30000).fill(rect); }],
]) {
  const f = fixture();
  alter(f);
  assert.throws(f.read, /scene_response_exceeds_1_mib/, `${name} must count toward full response bytes`);
}
console.log('scene resources: shared-script parity, insecure-context identity, observed href, and 6 JSON/UTF-8 overflow cases passed');
