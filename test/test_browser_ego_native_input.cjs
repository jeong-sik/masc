const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const file = path.join(__dirname, '../lib/browser_ego_peer.ml');
const peerSource = fs.readFileSync(file, 'utf8');
const source = peerSource.split('let target_input_script = {js|')[1].split('|js}')[0];
const run = vm.runInNewContext('(' + source + ')');
const initial = 'https://fixture.test/';
const args = {action:'drag_to',expectedUrl:initial,target:'@12',destination:'loc=css:#target',cursor:'MASC · fixture'};
function fixture(drag) {
  const calls=[];
  const page={
    url:async()=>initial,
    info:async()=>({url:initial}),
    dragAndDrop:async(...input)=>{calls.push(['drag',...input]);return drag(calls);},
    // The SDK can resolve mouse.up as void after a dialog interruption.
    mouse:{up:async()=>{calls.push(['up']);}},
  };
  return {page,calls};
}
test('a native drag completion preserves the original selector and receipt', async()=>{
  const receipt={popups:[]};
  const f=fixture(()=>receipt);
  const result=await run(f.page,args);
  assert.equal(result.receipt,receipt);
  assert.equal(result.error,null);
  assert.equal(f.calls.length,1);
  assert.deepEqual(f.calls[0].slice(0,3),['drag','@12','loc=css:#target']);
});
test('a native drag failure cannot turn void cleanup into release proof', async()=>{
  const f=fixture(()=>{throw Error('native drag interrupted');});
  const result=await run(f.page,args);
  assert.equal(result.error,'native drag interrupted');
  assert.equal(f.calls.filter(call=>call[0]==='up').length,0);
});
test('a drag already cleaned up by the SDK receives no duplicate release', async()=>{
  const f=fixture(calls=>{calls.push(['SDK-owned release']);throw Error('native result lost');});
  const result=await run(f.page,args);
  assert.equal(result.error,'native result lost');
  assert.equal(f.calls.filter(call=>call[0]==='SDK-owned release').length,1);
  assert.equal(f.calls.filter(call=>call[0]==='up').length,0);
});
test('a thrown error hands its declared name and kind to the host and nothing else', async()=>{
  class ElementResolutionError extends Error {
    constructor(message, kind) { super(message); this.name = 'ElementResolutionError'; this.kind = kind; }
  }
  const refused=fixture(()=>{throw new ElementResolutionError('Locator loc=css:#target matched 0 elements','permanent');});
  const result=await run(refused.page,args);
  assert.equal(result.error,'Locator loc=css:#target matched 0 elements');
  assert.equal(result.thrown.name,'ElementResolutionError');
  assert.equal(result.thrown.kind,'permanent');
  assert.equal(refused.calls.filter(call=>call[0]==='up').length,0);
  const plain=fixture(()=>{throw Error('native drag interrupted');});
  const other=await run(plain.page,args);
  assert.equal(other.thrown.name,'Error');
  assert.equal(other.thrown.kind,null);
  const odd=fixture(()=>{throw 'not an error object';});
  const none=await run(odd.page,args);
  assert.equal(none.thrown.name,null);
  assert.equal(none.thrown.kind,null);
  const served=await run(fixture(()=>({popups:[]})).page,args);
  assert.equal(served.thrown,null);
});
test('a dialog receipt keeps native drag release unconfirmed', async()=>{
  const receipt={dialog:{type:'alert',message:'hold'}};
  const f=fixture(()=>receipt);
  const result=await run(f.page,args);
  assert.equal(result.receipt,receipt);
  assert.equal(f.calls.length,1);
});
for (const [action, method] of [['click', 'click'], ['double_click', 'dblclick']]) {
  test(`a native ${action} preserves the SDK dialog receipt without replay or release`, async()=>{
    // Page.#runActionBoundary returns this receipt when PageDialogOpenedError
    // unwinds clickInPage, including a dialog opened during mousePressed.
    const receipt={dialog:{type:'alert',message:'mousedown interrupted',defaultPrompt:''}};
    const calls=[];
    const page={
      url:async()=>{calls.push('url');return initial;},
      [method]:async()=>{calls.push(method);return receipt;},
      mouse:{up:async()=>{calls.push('up');}},
    };
    const result=await run(page,{...args,action});
    assert.equal(result.receipt,receipt);
    assert.equal(result.error,null);
    assert.deepEqual(calls,['url',method]);
  });
}

const guardSource = peerSource.split('let native_type_guard_script = {js|')[1].split('|js}')[0];
const pageCall = JSON.parse(peerSource.split('let page_call =\n')[1].split('\nlet on_page')[0].trim());
const guard = vm.runInNewContext(pageCall + '\n(' + guardSource + ')');
test('the fixed ordinary raw guard rejects malformed observations before typing', async () => {
  const args = {guard:'fixed host page guard', input:JSON.stringify({expectedUrl:initial, documentId:'d1'})};
  const valid = {url:initial, title:'Fixture', scrollX:0, scrollY:0};
  for (const checked of [null, {}, {pageError:'wrong document'}, {answer:'not JSON'},
    {answer:'{}'}, {answer:JSON.stringify({...valid, url:'https://other.test/'})},
    {answer:JSON.stringify({...valid, title:null})}, {answer:JSON.stringify({...valid, scrollX:null})},
    {answer:JSON.stringify({...valid, private:'unrequested'})},
    {answer:JSON.stringify(valid), private:'unrequested'}]) {
    let types = 0;
    const page = {evaluate:async () => checked, keyboard:{type:async () => { types++; }}};
    await assert.rejects(async () => { await guard(page,args); await page.keyboard.type('a'); },
      /native input guard refused/);
    assert.equal(types,0,'malformed fixed-guard response cannot admit holding input');
  }
  let types = 0;
  const page = {evaluate:async () => ({answer:JSON.stringify(valid)}), keyboard:{type:async () => { types++; }}};
  await guard(page,args); await page.keyboard.type('a');
  assert.equal(types,1,'the declared fixed-guard result permits the next producer stage');
});
