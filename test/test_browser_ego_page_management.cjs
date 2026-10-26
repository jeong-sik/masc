const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync(path.join(__dirname, '../lib/browser_ego_peer.ml'), 'utf8')
  .split('let page_management_script = {js|')[1].split('|js}')[0];
const run = vm.runInNewContext('(' + source + ')');
function fixture({label=null, origin='unknown', missing=false, fail=false, wrong=false}={}) {
  const calls=[];
  const handle={targetId:'T9',openedBy:origin};
  const tab={label,targetId:'T9',openedBy:origin,page:handle};
  const task={
    tabs:async()=>missing ? [] : [tab],
    adopt:async(page, options)=>{
      assert.equal(page,handle);
      calls.push(['adopt',options.as]);
      if (fail) throw Error('SDK response lost');
      return {label:options.as ?? 'generated',targetId:wrong ? 'other' : 'T9',openedBy:origin};
    },
    release:async(value)=>{
      assert.equal(value,label);
      calls.push(['release',value]);
      if (fail) throw Error('SDK response lost');
      return {targetId:wrong ? 'other' : 'T9',openedBy:origin};
    },
    // Page operations and Space-control transfers are deliberately unavailable.
  };
  return {task,calls};
}
test('adoption passes the actual unmanaged handle and preserves explicit or SDK-generated labels', async()=>{
  for (const pageLabel of [undefined,'login']) {
    const f=fixture();
    const result=await run(f.task,{action:'adopt_tab',targetId:'T9',...(pageLabel ? {pageLabel} : {})});
    assert.equal(result.ok,true);
    assert.equal(result.value.label,pageLabel ?? 'generated');
    assert.equal(result.value.targetId,'T9');
    assert.equal(result.value.openedBy,'unknown');
    assert.deepEqual(f.calls,[['adopt',pageLabel]]);
  }
});
test('missing, replaced and already-managed tabs cause no adoption', async()=>{
  for (const config of [{missing:true},{label:'already'},{origin:'agent'}]) {
    const f=fixture(config);
    const result=await run(f.task,{action:'adopt_tab',targetId:'T9'});
    assert.equal(result.before,true);
    assert.deepEqual(f.calls,[]);
  }
  const f=fixture();
  assert.equal((await run(f.task,{action:'adopt_tab',targetId:'different'})).before,true);
  assert.deepEqual(f.calls,[]);
});
test('release preserves the browser tab and its unknown origin', async()=>{
  const f=fixture({label:'borrowed'});
  const result=await run(f.task,{action:'release_tab',label:'borrowed'});
  assert.equal(result.ok,true);
  assert.equal(result.value.label,null);
  assert.equal(result.value.targetId,'T9');
  assert.equal(result.value.openedBy,'unknown');
  assert.deepEqual(f.calls,[['release','borrowed']]);
});
test('release refuses agent-created, unmanaged and absent Pages', async()=>{
  for (const config of [{label:'borrowed',origin:'agent'},{label:'borrowed',missing:true},{label:null}]) {
    const f=fixture(config);
    const result=await run(f.task,{action:'release_tab',label:'borrowed'});
    assert.equal(result.before,true);
    assert.deepEqual(f.calls,[]);
  }
});
test('SDK failure is preserved without replay or compensating calls', async()=>{
  for (const action of ['adopt_tab','release_tab']) {
    const f=fixture({label:action==='adopt_tab' ? null : 'borrowed',fail:true});
    await assert.rejects(run(f.task,{action,targetId:'T9',label:'borrowed'}),/SDK response lost/);
    assert.equal(f.calls.length,1);
  }
});
test('a response with a different target cannot establish a Page binding', async()=>{
  for (const action of ['adopt_tab','release_tab']) {
    const f=fixture({label:action==='adopt_tab' ? null : 'borrowed',wrong:true});
    await assert.rejects(run(f.task,{action,targetId:'T9',label:'borrowed'}),/changed Page identity or origin/);
    assert.equal(f.calls.length,1);
  }
});
