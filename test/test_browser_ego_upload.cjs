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

// Exercise the actual chooser body sent to the SDK, with one persistent page.
const peer=fs.readFileSync(require('node:path').join(__dirname,'../lib/browser_ego_peer.ml'),'utf8');
const chooserBody=peer.slice(peer.indexOf('let choose_files ')).match(/      "      let failure = null[\s\S]*?(?=      "      const dialog)/)?.[0];
assert(chooserBody);
const choose=vm.runInNewContext('(async(page,args,reason)=>{'+chooserBody.split('\n').filter(line=>line.trim()).map(line=>JSON.parse(line.trim().replace(/;$/,''))).join('\n')+';return {failure,set};})');

test('a rejected file assignment releases the chooser so a later upload can run',async()=>{
 let pending=false,fail=true;const assignments=[];
 const page={async waitForFileChooser(){
  if(pending)throw Error('this Page is already waiting for a file chooser');
  pending=true;return {async setFiles(paths){assignments.push([...paths]);if(paths.length&&fail)throw Error('assignment failed');pending=false;return {};}};
 },async click(){}};
 const args={opener:'@12',cursor:'MASC',paths:['/staged/note.txt']};
 const first=await choose(page,args,String);
 assert.match(first.failure,/assignment failed/);assert.equal(first.set,null);
 assert.equal(pending,false);assert.deepEqual(assignments,[args.paths,[]]);
 fail=false;const next=await choose(page,args,String);
 assert.equal(next.failure,null);assert.equal(pending,false);assert.deepEqual(assignments,[args.paths,[],args.paths]);
});

test('failed chooser cleanup preserves both errors and never retries the requested files',async()=>{
 const assignments=[];
 const chooser={async setFiles(paths){assignments.push([...paths]);throw Error(paths.length?'assignment failed':'cleanup failed');}};
 const result=await choose({async waitForFileChooser(){return chooser;},async click(){}},{opener:'@12',paths:['/staged/note.txt']},String);
 assert.match(result.failure,/assignment failed/);assert.match(result.failure,/cleanup failed/);assert.match(result.failure,/next chooser upload may be refused/);
 assert.deepEqual(assignments,[['/staged/note.txt'],[]]);assert.equal(result.set,null);
});
