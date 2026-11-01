const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync(path.join(__dirname,'../lib/browser_ego_recovery.ml'),'utf8')
  .match(/let script = \{js\|([\s\S]*?)\|js\}/)?.[1];
assert.ok(source);
const recover = vm.runInNewContext('('+source+')');
function fixture({label='p1',origin='agent',target='T1',foreignPage=false,foreignSpace=false,duplicate=false,fail=false}={}) {
  const calls=[];
  const observed={label,targetId:target,openedBy:origin};
  const page={spaceId:foreignSpace?99:51,label:'p1',targetId:foreignPage?'T2':'T1',openedBy:origin,
    async cdp(method,...params){calls.push([method,...params]);if(fail)throw Error('lost after native stop');return {};}};
  for(const method of ['url','info','snapshot','title','goto','reload','evaluate'])
    page[method]=async()=>{throw Error('EGO_PAGE_UNRESPONSIVE');};
  observed.page=page;
  // Native task.page(label) is lightweight: it does not expose targetId or
  // openedBy. Only the inventory row carries the canonical enriched Page.
  const task={spaceId:51,tabs:async()=>duplicate?[observed,observed]:[observed],
    page:requested=>{assert.equal(requested,'p1');return {spaceId:51,label:'p1',cdp:page.cdp};}};
  return {task,calls};
}
test('loading recovery does not depend on any responsive Page observation',async()=>{
  for(const origin of ['agent','unknown']) {
    const {task,calls}=fixture({origin});
    const result=await recover(task,{label:'p1'});
    assert.equal(result.ok,true);assert.equal(result.value.returned,true);
    assert.equal(result.value.spaceId,51);assert.equal(result.value.openedBy,origin);
    assert.equal(result.value.targetId,'T1');assert.equal(result.value.label,'p1');
    assert.deepEqual(calls,[['Page.stopLoading']]);
    for(const key of ['url','expectedUrl','ready','inputReleased'])assert.equal(Object.hasOwn(result.value,key),false);
  }
});
test('only the exact managed native Page receives recovery',async()=>{
  for(const options of [{label:null},{label:'p2'},{origin:'user'},{target:''},{target:'  '},
    {foreignPage:true},{foreignSpace:true},{duplicate:true}]) {
    const {task,calls}=fixture(options);const result=await recover(task,{label:'p1'});
    assert.equal(result.ok,false);assert.equal(result.before,true);assert.deepEqual(calls,[]);
  }
});
test('an uncertain native stop is not retried or converted into success',async()=>{
  const {task,calls}=fixture({fail:true});
  await assert.rejects(recover(task,{label:'p1'}),/lost after native stop/);
  assert.deepEqual(calls,[['Page.stopLoading']]);
});
