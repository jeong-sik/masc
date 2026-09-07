const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync(path.join(__dirname,'../connectors/browser/extension/background.js'),'utf8');
function fixture({navigates=false,encoded='cGl4ZWxz'}={}) {
  let reads=0; const captures=[], replies=[];
  const port={onMessage:{addListener(){}},onDisconnect:{addListener(){}},postMessage(reply){replies.push(JSON.parse(JSON.stringify(reply)));}};
  const context=vm.createContext({TextEncoder,clearTimeout(){},setTimeout(){},browser:{
    runtime:{connectNative(){return port;}},
    tabs:{async get(id){assert.equal(id,73);return {url: navigates && reads++ ? 'https://example.org/new':'https://example.org/old',title:'Page'};},
      async captureTab(id,options){captures.push([id,options.format]);return 'data:image/png;base64,'+encoded;}}
  }});
  vm.runInContext(source,context);
  return {context,captures,replies};
}
test('capture names the requested tab without selecting or querying the active tab',async()=>{
  const f=fixture();
  const result=await vm.runInContext('pageScreenshot({tabId:73})',f.context);
  assert.equal(result.tabId,73);assert.equal(result.url,'https://example.org/old');
  assert.deepEqual(f.captures,[[73,'png']]);
  await assert.rejects(vm.runInContext('pageScreenshot({})',f.context),/requires_tab_id/);
});
test('navigation during capture discards ambiguous pixels',async()=>{
  const f=fixture({navigates:true});
  await assert.rejects(vm.runInContext('pageScreenshot({tabId:73})',f.context),/navigated_during/);
});
test('oversized reply becomes a bounded error before native messaging',async()=>{
  const f=fixture({encoded:'A'.repeat(8*1024*1024)});
  await vm.runInContext('onHostMessage({id:"shot",verb:"page.screenshot",args:{tabId:73}})',f.context);
  assert.deepEqual(f.replies,[{id:'shot',ok:false,error:'browser_reply_exceeds_8_mib'}]);
});
