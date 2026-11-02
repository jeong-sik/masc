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

// Exercise the actual production inventory/dialog scripts, with no SDK or browser.
const peerSource=fs.readFileSync(path.join(__dirname,'../lib/browser_ego_peer.ml'),'utf8');
const script=name=>vm.runInNewContext('('+peerSource.split('let '+name+' = {js|')[1].split('|js}')[0]+')');
const inventory=script('tab_inventory_script');
const resolveDialogPage=script('dialog_page_script');
const answerDialog=script('dialog_answer_script');
const readDialog=script('dialog_read_script');
const dialogArgs={spaceId:20,label:'p1',accept:false,text:null};
function dialogFixture() {
  const calls=[];
  const page={spaceId:20,label:'p1',targetId:'T1',openedBy:'agent',
    info:async()=>{calls.push('info');throw Error('CDP request timed out: Runtime.evaluate');},
    dismissDialog:async()=>{calls.push('dismiss');return true;},
    acceptDialog:async text=>{calls.push(['accept',text]);return true;}};
  const row={label:'p1',targetId:'T1',openedBy:'agent',title:'Owned modal',url:'https://example.test/',active:true,page};
  const task={spaceId:20,tabs:async()=>[row],page:()=>{throw Error('sparse task.page handle is not canonical inventory authority');}};
  return {task,row,page,calls};
}
test('bare native inventory and direct answer never require blocked Page.info',async()=>{
  const f=dialogFixture();
  assert.equal((await inventory(f.task))[0].targetId,'T1');
  assert.deepEqual(f.calls,[]);
  await assert.rejects(readDialog(f.task,dialogArgs,resolveDialogPage),/Runtime.evaluate/);
  assert.equal((await inventory(f.task))[0].label,'p1');
  const result=await answerDialog(f.task,dialogArgs,resolveDialogPage,()=>{});
  assert.equal(result.ok,true);
  assert.equal(result.value.answered,true);
  assert.equal(Object.hasOwn(result.value,'dialog'),false);
  assert.deepEqual(f.calls,['info','dismiss']);
});
test('dialog answer validates fresh canonical identity before any watcher or method',async()=>{
  for(const mutate of [
    f=>{f.task.spaceId=21;},f=>{f.task.tabs=async()=>[];},
    f=>{f.task.tabs=async()=>[f.row,f.row];},f=>{f.row.targetId=' ';},
    f=>{f.page.targetId='replacement';},f=>{f.page.spaceId=21;},
    f=>{f.page.label='p2';},f=>{f.page.openedBy='unknown';},
    f=>{f.row.openedBy='foreign';},f=>{delete f.row.page;}
  ]) {
    const f=dialogFixture();mutate(f);
    const result=await answerDialog(f.task,dialogArgs,resolveDialogPage,()=>f.calls.push('watch'));
    assert.equal(result.before,true);
    assert.deepEqual(f.calls,[]);
  }
});
test('native strict booleans and exact prompt text determine the dialog answer',async()=>{
  for(const answer of [true,false,undefined,null,1,'true']) {
    const f=dialogFixture();let count=0;
    f.page.acceptDialog=async text=>{assert.equal(text,'');count++;return answer;};
    const result=await answerDialog(f.task,{...dialogArgs,accept:true,text:''},resolveDialogPage,()=>{});
    assert.equal(count,1);
    if(answer===true) assert.equal(result.value.answered,true);
    else if(answer===false) assert.equal(result.before,true);
    else {assert.equal(result.ok,false);assert.notEqual(result.before,true);}
    assert.deepEqual(f.calls,[]);
  }
});
test('explicit native info needs an observed dialog or the complete documented document state',async()=>{
  const normal={url:'https://example.test/',title:'Owned',w:800,h:600,sx:0,sy:0,pw:800,ph:600};
  for(const info of [normal,{dialog:{type:'alert',message:'owned'}},{},null,[],
    {...normal,w:NaN},{...normal,title:undefined},{dialog:null},{dialog:'alert'}]) {
    const f=dialogFixture();f.page.info=async()=>{f.calls.push('info');return info;};
    const result=await readDialog(f.task,dialogArgs,resolveDialogPage);
    assert.deepEqual(f.calls,['info']);
    if(info===normal) {assert.equal(result.ok,true);assert.equal(result.value.dialog,null);}
    else if(info?.dialog?.type==='alert') {assert.equal(result.ok,true);assert.equal(result.value.dialog,info.dialog);}
    else {assert.equal(result.ok,false);assert.equal(result.before,true);}
  }
});
