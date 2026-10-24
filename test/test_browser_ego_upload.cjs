const assert=require('node:assert/strict');
const test=require('node:test');
const fs=require('node:fs');
const vm=require('node:vm');
const source=fs.readFileSync(require('node:path').join(__dirname,'../lib/browser_ego_peer.ml'),'utf8').match(/let native_upload_script = \{js\|([\s\S]*?)\|js\}/)?.[1];
assert(source);const upload=vm.runInNewContext('('+source+')');
test('file inputs, labels, wrappers, snapshot refs and frame/shadow locators go directly to the SDK',async()=>{
 for(const selector of ['#file','@12','loc=css:#label','loc=css:#wrapper','loc=css:#shadowfile','loc=role:button[name="Choose"]']){
  const calls=[], paths=['/staged/note.txt'];const receipt={dialog:{type:'alert',message:'selected'}};
  const result=await upload({async setInputFiles(...args){calls.push(args);return receipt;}},{selector,paths});
  assert.equal(result.receipt,receipt);assert.equal(result.error,null);assert.deepEqual(calls,[[selector,paths]]);
 }
});
test('an SDK failure remains uncertain and does not read or replay input',async()=>{
 let calls=0;const result=await upload({async setInputFiles(){calls++;throw Error('control lost');}},{selector:'@12',paths:['/staged/note.txt']});
 assert.equal(calls,1);assert.equal(result.error,'control lost');assert.equal(result.receipt,null);
});
