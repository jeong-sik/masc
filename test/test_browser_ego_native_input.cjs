const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const file = path.join(__dirname, '../lib/browser_ego_peer.ml');
const source = fs.readFileSync(file, 'utf8').split('let target_input_script = {js|')[1].split('|js}')[0];
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
test('a dialog receipt keeps native drag release unconfirmed', async()=>{
  const receipt={dialog:{type:'alert',message:'hold'}};
  const f=fixture(()=>receipt);
  const result=await run(f.page,args);
  assert.equal(result.receipt,receipt);
  assert.equal(f.calls.length,1);
});
