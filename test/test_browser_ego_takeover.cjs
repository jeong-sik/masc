const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const test=require('node:test');
const source=fs.readFileSync(path.join(__dirname,'../lib/browser_ego_takeover.ml'),'utf8').split('let script = {js|')[1].split('|js}')[0];
const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
const execute=new AsyncFunction('task','args','takeOverTaskSpace','emit',source);
const identity=(extra={})=>({spaceId:51,targetId:'T1',label:'p1',openedBy:'agent',...extra});
function fixture({boundary=identity(),rows,taskId=51,back={},onTabs}={}) {
 const calls=[],emitted=[];
 const forbidden=name=>()=>{calls.push(name);throw Error('unexpected '+name);};
 const space={spaceId:51,name:'Renamed Space',ownership:'agent',...back,
  userPage(){calls.push('userPage');return boundary;},
  async tabs(){calls.push('tabs');await Promise.resolve();if(onTabs)onTabs();
   return rows===undefined?[identity(),identity({targetId:'T9',label:'other',active:true})]:rows;},
  page:forbidden('page'),adoptPage:forbidden('adoptPage'),click:forbidden('click')};
 return {calls,emitted,boundary,
  run:()=>execute({spaceId:taskId},{spaceId:51},async id=>{
   calls.push(['takeOverTaskSpace',id]);return space;
  },value=>emitted.push(value))};
}
test('native takeover preserves managed and unmanaged user-boundary identity',async()=>{
 for(const page of [identity(),identity({label:null,openedBy:'unknown'})]) {
  const row={targetId:page.targetId,label:page.label,openedBy:page.openedBy,active:false};
  const f=fixture({boundary:page,rows:[row,identity({targetId:'active-other',label:'other',active:true})]});
  await f.run();
  assert.deepEqual(f.emitted,[{ok:true,value:{spaceId:51,spaceName:'Renamed Space',
   page:{targetId:page.targetId,label:page.label,openedBy:page.openedBy}}}]);
  assert.deepEqual(f.calls,[['takeOverTaskSpace',51],'userPage','tabs']);
 }
});
test('an absent native boundary stays absent without inventory or active-page fallback',async()=>{
 const emitted=[],calls=[];
 await execute({spaceId:51},{spaceId:51},async id=>{calls.push(id);return {
  spaceId:51,name:'Space',ownership:'agent',userPage:()=>undefined,
  tabs:()=>{throw Error('absent boundary must not read current active tabs');}};},value=>emitted.push(value));
 assert.deepEqual(calls,[51]);assert.deepEqual(emitted,[{ok:true,value:{spaceId:51,spaceName:'Space',page:null}}]);
});
test('a changed original Space refuses before the native takeover',async()=>{
 const f=fixture({taskId:52});await f.run();
 assert.deepEqual(f.calls,[]);assert.equal(f.emitted.length,1);
 assert.equal(f.emitted[0].ok,false);assert.equal(f.emitted[0].before,true);
});
test('a foreign or unreadable post-takeover Space cannot supply a Page',async()=>{
 for(const back of [{spaceId:52},{ownership:'user'},{ownership:'agentDelegatedToUser'},{name:''},{name:null}]) {
  const f=fixture({back});await assert.rejects(f.run());
  assert.deepEqual(f.calls,[['takeOverTaskSpace',51]]);assert.deepEqual(f.emitted,[]);
 }
});
test('invalid boundary handles never fall back to current active tabs',async()=>{
 for(const boundary of [null,{},identity({spaceId:52}),identity({targetId:''}),
  identity({label:''}),identity({openedBy:'user'}),identity({label:3})]) {
  const f=fixture({boundary});await assert.rejects(f.run());
  assert.deepEqual(f.calls,[['takeOverTaskSpace',51],'userPage']);assert.deepEqual(f.emitted,[]);
 }
});
test('missing, duplicate or changed target provenance is uncertain after the single takeover',async()=>{
 for(const rows of [null,[],[identity(),identity()],
  [identity({targetId:'other'})],[identity({label:'changed'})],[identity({openedBy:'unknown'})]]) {
  const f=fixture({rows});await assert.rejects(f.run());
  assert.deepEqual(f.calls,[['takeOverTaskSpace',51],'userPage','tabs']);assert.deepEqual(f.emitted,[]);
 }
});
test('the boundary is frozen before awaiting tabs and ignores later active-page changes',async()=>{
 const boundary=identity();
 const f=fixture({boundary,rows:[identity(),identity({targetId:'T9',label:'active-later',active:true})],
  onTabs:()=>Object.assign(boundary,{targetId:'T9',label:'active-later',openedBy:'unknown',spaceId:99})});
 await f.run();assert.deepEqual(f.emitted[0].value.page,{targetId:'T1',label:'p1',openedBy:'agent'});
 const changed=identity();
 const bad=fixture({boundary:changed,rows:[identity({targetId:'T2',label:'p2'})],
  onTabs:()=>Object.assign(changed,{targetId:'T2',label:'p2'})});
 await assert.rejects(bad.run());assert.deepEqual(bad.emitted,[]);
});
