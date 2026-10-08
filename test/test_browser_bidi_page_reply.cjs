const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const root = path.resolve(__dirname, '..');
const peer = fs.readFileSync(path.join(root, 'lib/browser_bidi_peer.ml'), 'utf8');
const runtime = peer.split('let page_reply_runtime = {js|')[1].split('|js}')[0];
const elements = fs.readFileSync(path.join(root, 'lib/browser_page_script.ml'), 'utf8')
  .split('let elements = {|')[1].split('|}')[0];
const documentRuntime = fs.readFileSync(path.join(root, 'lib/browser_lane/browser_document.ml'), 'utf8')
  .split('let runtime = {js|')[1].split('|js}')[0];
// Load the actual prefix used by the BiDi inventory dispatch, then execute it
// with the shipped observation and serialization scripts against a page.
const loadingPrefix = JSON.parse(peer.match(/"if \(document.readyState === 'loading'\) return \{documentLoading:true\};\\n"/)[0]);
function fixture() {
  const control = {localName:'textarea',nodeType:1,parentElement:null,
    innerText:'',value:'healthy',getAttribute:()=>null,getClientRects:()=>[{}],
    matches:()=>false};
  const window = {}; window.top = window;
  const context = vm.createContext({TextEncoder,window,
    browserScene:()=>({documentId:'same-document'}),
    document:{readyState:'complete',title:'fixture',documentElement:{outerHTML:'<html></html>'},
      querySelectorAll:()=>[control]},
    location:{href:'https://example.test/'},getComputedStyle:()=>({visibility:'visible',display:'block',opacity:'1'})});
  function read(body) {
    const encoded = vm.runInContext(`${runtime}\n${documentRuntime}\nbrowserBidiReply(function(){${body}})`,context);
    // BiDi sends a JSON string inside another JSON frame. Measure that wire,
    // not only the unescaped inner payload.
    const wire=JSON.stringify({type:'success',id:1,result:{type:'success',realm:'fixture',result:{type:'string',value:encoded}}});
    assert.ok(Buffer.byteLength(wire)<8*1024*1024);
    return JSON.parse(encoded);
  }
  return {control,context,elements:()=>read(loadingPrefix+elements),
    document:()=>read('return browserDocument();')};
}
test('normal inventory preserves values and oversized current value is locally refused',()=>{
  const f=fixture();assert.equal(f.elements().elements[0].value,'healthy');
  f.control.value='😀'.repeat(3*1024*1024);
  assert.deepEqual(f.elements(),{pageReplyTooLarge:true});
  f.control.value='recovered';assert.equal(f.elements().elements[0].value,'recovered');
});
test('large option inventory is refused before the escaped BiDi response',()=>{
  const f=fixture();f.control.localName='select';f.control.options=Array.from({length:2000},()=>({value:'x'.repeat(5000),label:'large'}));
  assert.deepEqual(f.elements(),{pageReplyTooLarge:true});
});
test('loading elements return a retryable observation without reading partial controls',()=>{
  const f=fixture();f.context.document.readyState='loading';
  f.context.document.querySelectorAll=()=>{throw new Error('partial controls must not be read');};
  assert.deepEqual(f.elements(),{documentLoading:true});
});
for(const metadata of ['title','url']) test(`oversized document ${metadata} is refused even after HTML is omitted`,()=>{
  const f=fixture();if(metadata==='title')f.context.document.title='x'.repeat(9*1024*1024);
  else f.context.location.href='https://example.test/'+ 'x'.repeat(9*1024*1024);
  assert.deepEqual(f.document(),{pageReplyTooLarge:true});
});
test('large HTML retains same-document identity and explicit missing-source result',()=>{
  const f=fixture();f.context.document.documentElement.outerHTML='x'.repeat(2*1024*1024);
  const p=f.document();assert.equal(p.html,null);assert.equal(p.htmlComplete,false);
  assert.equal(p.documentId,'same-document');assert.equal(p.htmlUnavailableReason,'document_html_exceeds_1_mib');
});
test('control-character escaping stays below the WebSocket frame boundary',()=>{
  const f=fixture();f.control.value='\0'.repeat(1024*1024);
  assert.deepEqual(f.elements(),{pageReplyTooLarge:true});
});
