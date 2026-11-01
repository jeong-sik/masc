const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const test=require('node:test');
const source=fs.readFileSync(path.join(__dirname,'../lib/browser_ego_workflow.ml'),'utf8').split('let script = {js|')[1].split('|js}')[0];
const run=vm.runInNewContext('('+source+')');
const start='https://fixture.test/opener',childUrl='https://fixture.test/child';
function fixture({clickError,eventError,raw={},duplicate=false,dialog,watchError=false,receipt}={}) {
 const calls=[];let resolve,reject,settled=false,value='';
 const waiting=new Promise((yes,no)=>{resolve=p=>{settled=true;yes(p);};reject=e=>{settled=true;no(e);};});
 const child={spaceId:51,label:'p2',targetId:'T2',openedBy:'agent',
  async url(){calls.push('child.url');return childUrl;},async title(){return 'Child';},async info(){return {};},
  async waitForURL(...args){calls.push(['child.waitForURL',...args]);},
  async fill(selector,text){calls.push(['child.fill',selector,text]);value=text;return {};},
  async snapshot(){calls.push('child.snapshot');return 'child '+value;},
  keyboard:{async type(){calls.push('child.type');}},
 };
 const eventPage={spaceId:51,label:'p2',...raw};
 const opener={spaceId:51,label:'p1',targetId:'T1',openedBy:'agent',
  async url(){calls.push('opener.url');return start;},async info(){return {};},
  waitForEvent(...args){calls.push(['waitForEvent',...args]);return waiting;},
  async click(...args){
   calls.push(['click',...args]);
   // Scheduling order stands in for a later native event; there is no host
   // timeout or action replay in the production script.
   Promise.resolve().then(()=>eventError?reject(eventError):resolve(eventPage));
   if(clickError)throw clickError;
   return receipt===undefined?(dialog?{dialog}:{}):receipt;
  },
 };
 const row=page=>({label:page.label,targetId:page.targetId,openedBy:page.openedBy,page});
 const task={spaceId:51,async tabs(){calls.push('tabs');return [row(opener),row(child),...(duplicate?[row(child)]:[])];}};
 const lightweight={spaceId:51,label:'p1',url:opener.url};
 const watch=(page,label)=>{calls.push(['watch',page.label,label]);if(watchError)throw Error('download observation failed');};
 return {calls,task,lightweight,watch,settled:()=>settled};
}
const request=steps=>({inputReceiptContract:{declaredMembers:['popups','dialog'],popupMembers:['label','targetId'],requiredPopupStringMembers:['label','targetId']},expectedSourcePage:{spaceId:51,label:'p1',targetId:'T1',openedBy:'agent'},expectedUrl:start,steps,maxChars:1000,snapshotScope:'viewport',cursor:'Owned popup fixture',label:'p1'});
const popup={method:'clickAndWaitForPopup',selector:'a[target="_blank"]'};
const fill={method:'fill',selector:'input',text:'same-process child'};
function count(calls,name){return calls.filter(x=>Array.isArray(x)?x[0]===name:x===name).length;}
test('pre-arms native event once, reconciles sparse handle, then continues and observes the canonical child',async()=>{
 const f=fixture(),result=await run(f.lightweight,request([popup,{method:'waitForURL',url:childUrl},fill]),f.task,f.watch);
 assert.equal(result.failure,null);assert.equal(result.snapshot,'child same-process child');assert.equal(result.url,childUrl);
 assert.equal(result.pages.source.label,'p1');assert.equal(result.pages.current.label,'p2');
 assert.equal(result.pages.current.targetId,'T2');assert.equal(result.pages.transitions[0].selected,true);
 assert.equal(result.completed.length,3);assert.equal(Object.hasOwn(result,'pendingAction'),false);
 assert.equal(count(f.calls,'click'),1);assert.equal(count(f.calls,'waitForEvent'),1);
 assert.ok(f.calls.findIndex(x=>x[0]==='waitForEvent')<f.calls.findIndex(x=>x[0]==='click'));
 assert.equal(f.calls.find(x=>x[0]==='waitForEvent')[2],undefined,'omission preserves native default');
 assert.equal(count(f.calls,'child.fill'),1);assert.equal(count(f.calls,'child.snapshot'),1);assert.equal(f.settled(),true);
});
test('explicit native popup/click options pass unchanged',async()=>{
 const f=fixture(),step={...popup,popupOptions:{timeout:0},options:{timeout:23,delay:7}};
 const result=await run(f.lightweight,request([step]),f.task,f.watch);
 assert.equal(result.failure,null);assert.equal(f.calls.find(x=>x[0]==='waitForEvent')[2].timeout,0);
 const sent=f.calls.find(x=>x[0]==='click')[2];assert.equal(sent.timeout,23);assert.equal(sent.delay,7);
});
test('a returned trigger and failed event wait preserve partial effect and exact receipt without replay',async()=>{
 const error=Object.assign(new Error('native popup wait failed'),{name:'TimeoutError',code:'EGO_EVENT_TIMEOUT',timeoutMs:37});
 const f=fixture({eventError:error}),result=await run(f.lightweight,request([popup,fill]),f.task,f.watch);
 assert.equal(result.failure.method,'popupWait');assert.equal(result.failure.eventError.code,'EGO_EVENT_TIMEOUT');
 assert.equal(result.failure.eventError.timeoutMs,37);assert.equal(result.pendingAction.index,0);
 assert.equal(Object.keys(result.pendingAction.receipt).length,0);assert.equal(result.completed.length,0);
 assert.equal(result.completedEffect,true);assert.equal(result.inputReleased,true);assert.equal(result.pages.current.label,'p1');
 assert.equal(count(f.calls,'click'),1);assert.equal(count(f.calls,'child.fill'),0);assert.equal(count(f.calls,'child.snapshot'),0);
 assert.equal(f.settled(),true);
});
test('trigger failure still drains the waiter and preserves an observed child without selecting or operating it',async()=>{
 const f=fixture({clickError:Error('trigger response lost')}),result=await run(f.lightweight,request([popup,fill]),f.task,f.watch);
 assert.equal(result.failure.method,'clickAndWaitForPopup');assert.equal(result.inputReleased,false);
 assert.equal(Object.hasOwn(result,'pendingAction'),false);assert.equal(result.pages.current.label,'p1');
 assert.equal(result.pages.transitions[0].popup.label,'p2');assert.equal(result.pages.transitions[0].selected,false);
 assert.equal(f.settled(),true);assert.equal(count(f.calls,'click'),1);assert.equal(count(f.calls,'child.fill'),0);
});
test('foreign, unmanaged, mismatching or ambiguous event identity never authorizes child input',async()=>{
 for(const options of [{raw:{spaceId:99}},{raw:{label:null}},{raw:{targetId:'foreign'}},{raw:{openedBy:'unknown'}},{duplicate:true}]) {
  const f=fixture(options),result=await run(f.lightweight,request([popup,fill]),f.task,f.watch);
  assert.equal(result.failure.method,'popupIdentity');assert.equal(result.pendingAction.index,0);
  assert.equal(result.pages.current.label,'p1');assert.equal(result.pages.transitions.length,0);
  assert.equal(count(f.calls,'click'),1);assert.equal(count(f.calls,'child.fill'),0);assert.equal(f.settled(),true);
 }
});
test('dialog interruption keeps release uncertain and consumes the popup waiter',async()=>{
 const f=fixture({dialog:{type:'alert',message:'fixture'},eventError:Error('no popup')}),result=await run(f.lightweight,request([popup,fill]),f.task,f.watch);
 assert.equal(result.inputReleased,false);assert.equal(result.pendingAction.receipt.dialog.message,'fixture');
 assert.equal(result.failure.dialog.message,'fixture');assert.equal(count(f.calls,'child.fill'),0);assert.equal(f.settled(),true);
});
test('child observation setup failure preserves acquired identity without claiming the switch completed',async()=>{
 const f=fixture({watchError:true}),result=await run(f.lightweight,request([popup,fill]),f.task,f.watch);
 assert.equal(result.pages.current.label,'p1');assert.equal(result.pages.transitions[0].selected,false);
 assert.equal(result.pendingAction.index,0);assert.equal(result.completed.length,0);assert.equal(count(f.calls,'child.fill'),0);
});
test('ordinary receipt-less child typing retains the established input guard',async()=>{
 const f=fixture(),result=await run(f.lightweight,request([popup,{method:'keyboard.type',text:'abc'},fill]),f.task,f.watch);
 assert.equal(result.pages.current.label,'p2');assert.equal(result.completed.length,1);assert.equal(result.inputReleased,false);
 assert.equal(result.failure.method,'keyboard.type');assert.equal(count(f.calls,'child.type'),1);assert.equal(count(f.calls,'child.fill'),0);
});

test('the full host-observed source identity is checked before a popup trigger',async()=>{
 for(const changed of [{targetId:'replacement'},{openedBy:'unknown'},{spaceId:99},{label:'p9'}]) {
  const f=fixture(),args=request([popup,fill]);Object.assign(args.expectedSourcePage,changed);
  const result=await run(f.lightweight,args,f.task,f.watch);
  assert.equal(result.failure.method,'pageIdentity');assert.equal(result.effectStarted,false);
  assert.equal(count(f.calls,'click'),0);assert.equal(count(f.calls,'waitForEvent'),0);assert.equal(count(f.calls,'child.fill'),0);
 }
});
test('a malformed native-version trigger receipt cannot select or operate the acquired child',async()=>{
 for(const receipt of [{futureSDKField:true},{dialog:null},{popups:null},{popups:[{label:'p2'}]},
   {popups:[{label:'p2',targetId:'T2',future:true}]},[],true,new Date(0)]) {
  const f=fixture({receipt}),result=await run(f.lightweight,request([popup,fill]),f.task,f.watch);
  assert.equal(result.inputReleased,false);assert.equal(result.failure.method,'clickAndWaitForPopup');
  assert.equal(result.pages.current.label,'p1');assert.equal(result.pages.transitions[0].selected,false);
  assert.equal(count(f.calls,'child.fill'),0);assert.equal(count(f.calls,'watch'),0);assert.equal(f.settled(),true);
 }
});
test('the native declared popup receipt remains valid input-release evidence',async()=>{
 const f=fixture({receipt:{popups:[{label:'p2',targetId:'T2'}]}});
 const result=await run(f.lightweight,request([popup,fill]),f.task,f.watch);
 assert.equal(result.failure,null);assert.equal(result.inputReleased,true);assert.equal(count(f.calls,'child.fill'),1);
});
