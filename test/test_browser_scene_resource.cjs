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

function fixture({extraNodes = () => [], extraGlobals = {}} = {}) {
  const document = {title:'ordinary HTTP page', documentElement:{}, body:{childNodes:[]},
    baseURI:'http://example.test/path'};
  const style = {display:'block', visibility:'visible', opacity:'1', color:'rgb(0, 0, 0)',
    fontSize:'16px', fontWeight:'400', whiteSpace:'normal'};
  const link = {nodeType:1, localName:'a', innerText:'A', parentElement:null,
    isConnected:true, ownerDocument:document, childNodes:[],
    hasAttribute:name => name === 'href', getAttribute:() => null, matches:selector => selector !== ':disabled',
    getClientRects:() => [rect], click:() => {}};
  link.href='http://example.test/observed';
  document.body.childNodes.push(link);
  for (const node of extraNodes(document)) document.body.childNodes.push(node);
  const context = vm.createContext({document, window:{}, ...extraGlobals,
    location:{href:'http://example.test/path?identity=exact#fragment'},
    innerWidth:800, innerHeight:600, scrollX:0, scrollY:0,
    getComputedStyle:() => style, HTMLInputElement:class {}, HTMLTextAreaElement:class {},
    // Model insecure-context WebCrypto: getRandomValues exists, randomUUID does not.
    crypto:{getRandomValues:array => webcrypto.getRandomValues(array)}, TextEncoder, URL});
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

// XLink is the SVG spelling of href. An HTML anchor that carries only an
// xlink:href has an empty .href, and resolving "" against baseURI advertised
// the current page as the destination -- selecting that control reloaded the
// page instead of following anything.
class SVGAElement {}
const xlinkNode = (document, {svg, id}) => {
  const node = {nodeType:1, localName:'a', innerText:id, parentElement:null,
    isConnected:true, ownerDocument:document, childNodes:[],
    hasAttribute:() => false,
    hasAttributeNS:(ns, name) =>
      ns === 'http://www.w3.org/1999/xlink' && name === 'href',
    getAttribute:() => null, matches:selector => selector !== ':disabled',
    getClientRects:() => [rect]};
  if (!svg) { node.href = ''; return node; }
  return Object.assign(new SVGAElement(),
    {...node, href:{baseVal:'http://example.test/svg-destination'}});
};
const xlink = fixture({
  extraGlobals:{SVGAElement},
  extraNodes:document =>
    [xlinkNode(document, {svg:false, id:'H'}), xlinkNode(document, {svg:true, id:'S'})],
});
const withXlink = vm.runInContext("browserScene({mode:'read',maxChars:1000})", xlink.context);
assert.equal(withXlink.nodes.length, 3, 'both XLink anchors stay observed controls');
const [, htmlXlink, svgXlink] = withXlink.nodes;
assert.equal('href' in htmlXlink, false,
  'an HTML anchor with only xlink:href advertises no destination');
assert.equal(svgXlink.href, 'http://example.test/svg-destination',
  'an SVG anchor is still followed through XLink');
assert.equal(
  vm.runInContext("window[Symbol.for('masc.browser.scene.refs.v3')].links.size", xlink.context), 2,
  'the HTML XLink anchor never enters the link map');

// A recycled anchor remains the same DOM object, but not the same observation.
const recycled = fixture();
const observed = recycled.read();
recycled.context.reference = {mode:'resolve_link',documentId:observed.documentId,nodeId:observed.nodes[0].nodeId};
assert.equal(vm.runInContext('browserScene(reference)',recycled.context),recycled.link);
recycled.link.href='http://example.test/recycled';
assert.throws(() => vm.runInContext('browserScene(reference)',recycled.context), /scene_link_destination_changed/);
const reread=recycled.read();
assert.notEqual(reread.nodes[0].nodeId,observed.nodes[0].nodeId);
assert.throws(() => vm.runInContext('browserScene(reference)',recycled.context), /scene_node_detached/,
  'a newer read retires the old reference instead of repinning it');
recycled.context.reference.nodeId=reread.nodes[0].nodeId;
assert.equal(vm.runInContext('browserScene(reference)',recycled.context),recycled.link);
for (let revision=0;revision<100;revision++) {
  recycled.link.href='http://example.test/revision/'+revision;
  recycled.read();
}
const registry=vm.runInContext("window[Symbol.for('masc.browser.scene.refs.v3')]",recycled.context);
assert.equal(registry.nodes.size,1,'connected recycled anchor retains only its latest reference');
assert.equal(registry.links.size,1,'superseded href pins are retired');
assert.throws(() => vm.runInContext('browserScene(reference)',recycled.context), /scene_node_detached/);

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
