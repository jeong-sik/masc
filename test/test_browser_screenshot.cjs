const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync(path.join(__dirname,'../connectors/browser/extension/background.js'),'utf8');
// [pageCapture] observes the viewport before and after the pixels and refuses
// the capture when either the URL or the viewport moved between them, so the
// fixture answers [executeScript] the way the content script does.
function fixture({navigates=false,scrolls=false,encoded='cGl4ZWxz'}={}) {
  let reads=0, observations=0; const captures=[], replies=[], scripts=[];
  const viewport={scrollX:0,scrollY:0,innerWidth:1280,innerHeight:720,devicePixelRatio:1};
  const port={onMessage:{addListener(){}},onDisconnect:{addListener(){}},postMessage(reply){replies.push(JSON.parse(JSON.stringify(reply)));}};
  const context=vm.createContext({TextEncoder,clearTimeout(){},setTimeout(){},browser:{
    runtime:{connectNative(){return port;}},
    tabs:{async get(id){assert.equal(id,73);return {url: navigates && reads++ ? 'https://example.org/new':'https://example.org/old',title:'Page'};},
      async executeScript(id,options){assert.equal(id,73);scripts.push(options.code);
        return [scrolls && observations++ ? {...viewport,scrollY:400} : {...viewport}];},
      async captureTab(id,options){captures.push([id,options.format]);return 'data:image/png;base64,'+encoded;}}
  }});
  vm.runInContext(source,context);
  return {context,captures,replies,scripts,viewport};
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
  assert.deepEqual(result.viewport,f.viewport);
  // Once before the pixels and once after, so a move between them is seen.
  assert.equal(f.scripts.length,2);
  assert.match(f.scripts[0],/mode:"viewport"/);
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
  await vm.runInContext('onHostMessage({id:"shot",verb:"page.capture",args:{tabId:73}})',f.context);
  assert.deepEqual(f.replies,[{id:'shot',ok:false,error:'browser_reply_exceeds_8_mib'}]);
});
