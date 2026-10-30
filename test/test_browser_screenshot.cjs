const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync(path.join(__dirname,'../connectors/browser/extension/background.js'),'utf8');
// [pageCapture] observes the viewport before and after the pixels and refuses
// the capture when either the URL or the viewport moved between them. The
// fixture answers [executeScript] with the shape [browserScene({mode:
// "viewport"})] actually returns -- {documentId, width, height, scrollX,
// scrollY} -- because [click_at] later matches a point against those exact
// fields, and it records every browser call in one ordered list so the
// before-pixels/after-pixels bracket is observable rather than inferred from
// a count.
function fixture({navigates=false,scrolls=false,encoded='cGl4ZWxz'}={}) {
  let reads=0, observations=0; const calls=[], replies=[];
  const viewport={documentId:'d1',width:1280,height:720,scrollX:0,scrollY:0};
  const port={onMessage:{addListener(){}},onDisconnect:{addListener(){}},postMessage(reply){replies.push(JSON.parse(JSON.stringify(reply)));}};
  const context=vm.createContext({TextEncoder,AbortController,clearTimeout(){},setTimeout(){},browser:{
    runtime:{connectNative(){return port;}},
    tabs:{async get(id){assert.equal(id,73);return {url: navigates && reads++ ? 'https://example.org/new':'https://example.org/old',title:'Page'};},
      async executeScript(id,options){assert.equal(id,73);calls.push({call:'executeScript',code:options.code});
        return [scrolls && observations++ ? {...viewport,scrollY:400} : {...viewport}];},
      async captureTab(id,options){calls.push({call:'captureTab',format:options.format,tabId:id});
        return 'data:image/png;base64,'+encoded;}}
  }});
  vm.runInContext(source,context);
  // A getter, not a snapshot: the calls happen after fixture() returns.
  return {context,calls,replies,viewport,
    get captures(){return calls.filter(c=>c.call==='captureTab').map(c=>[c.tabId,c.format]);}};
}
test('capture names the requested tab without selecting or querying the active tab',async()=>{
  const f=fixture();
  const result=await vm.runInContext('pageCapture({tabId:73})',f.context);
  assert.equal(result.tabId,73);assert.equal(result.url,'https://example.org/old');
  assert.deepEqual(f.captures,[[73,'png']]);
  await assert.rejects(vm.runInContext('pageCapture({})',f.context),/tab_id_required/);
});
test('the capture carries the viewport it observed around the pixels',async()=>{
  const f=fixture();
  const result=await vm.runInContext('pageCapture({tabId:73})',f.context);
  // The exact fields click_at matches a point against, not a stand-in shape.
  assert.deepEqual(result.viewport,
    {documentId:'d1',width:1280,height:720,scrollX:0,scrollY:0});
  // One observation on each side of the pixels: both before, or both after,
  // would leave a move during the capture undetected.
  assert.deepEqual(f.calls.map(c=>c.call),
    ['executeScript','captureTab','executeScript']);
  assert.match(f.calls[0].code,/mode:"viewport"/);
});
test('navigation during capture discards ambiguous pixels',async()=>{
  const f=fixture({navigates:true});
  await assert.rejects(vm.runInContext('pageCapture({tabId:73})',f.context),
    /viewport_changed_during_capture/);
});
test('a viewport that moves during capture discards ambiguous pixels',async()=>{
  const f=fixture({scrolls:true});
  await assert.rejects(vm.runInContext('pageCapture({tabId:73})',f.context),
    /viewport_changed_during_capture/);
});
test('oversized reply becomes a bounded error before native messaging',async()=>{
  const f=fixture({encoded:'A'.repeat(8*1024*1024)});
  await vm.runInContext('onHostMessage({id:"shot",deadlineMs:Date.now()+20000,verb:"page.capture",args:{tabId:73}})',f.context);
  assert.deepEqual(f.replies,[{id:'shot',ok:false,error:'browser_reply_exceeds_8_mib'}]);
});
