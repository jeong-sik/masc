const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const os=require('node:os');
const vm=require('node:vm');
const test=require('node:test');
const source=fs.readFileSync(require('node:path').join(__dirname,'../lib/browser_ego_workflow.ml'),'utf8').split('let script = {js|')[1].split('|js}')[0];
const run=vm.runInNewContext('('+source+')');
const initial='https://fixture.test/start',destination='https://fixture.test/done';
function fixture({fail,dialog,snapshot='native result'}={}) {
 const calls=[];let url=initial,value='';
 const page={
  async url(){calls.push('url');return url;},async title(){calls.push('title');return 'Fixture';},
  async info(){return {};},
  async snapshot(options){
   calls.push(['snapshot',options]);
   if(options?.scope!==undefined&&!['full_page','only_within_viewport','subtree'].includes(options.scope))
    throw Error('page.snapshot scope must be one of full_page, only_within_viewport, subtree');
   return snapshot;
  },
 };
 for(const method of ['click','dblclick','hover','dragAndDrop','fill','press','selectOption','goto','waitForURL','waitForSelector','waitForLoadState'])page[method]=async(...args)=>{
  calls.push([method,...args]);if(method===fail)throw Error('native '+method+' failed');
  if(method==='fill')value=args[1];if(method==='goto'||method==='click')url=destination;
  if(method==='waitForURL')assert.equal(url,args[0]);
  if(method==='waitForSelector'&&args[1]?.state!=='attached')assert.equal(value,'changed');
  return dialog&&method==='click'?{dialog:{type:'alert',message:'hold'}}:method==='selectOption'?['b']:{};
 };
 return {page,calls};
}
const request=steps=>({expectedUrl:initial,steps,snapshotScope:'viewport',maxChars:100,cursor:'MASC · fixture · workflow'});
const downloadId='60c7683f-f552-4c01-a5cb-2d487bb62e5e';
function cancelFixture({state='pending',source:provenance='native_download',rowLabel='p1',handleLabel='p1',cancel}={}) {
 const f=fixture();let cancellations=0;
 const row={id:downloadId,label:rowLabel,source:provenance,state,path:null,reason:null};
 const context={mascDownloads:{rows:[row],handles:new Map([[downloadId,{label:handleLabel,
  download:{async cancel(){cancellations++;if(cancel)await cancel(row);}}}]])}};
 const invoke=vm.runInNewContext('('+source+')',context);
 return {...f,row,context,cancellations:()=>cancellations,
  invoke:steps=>invoke(f.page,{...request(steps),label:'p1'})};
}
test('native Download cancel calls its exact pending Page handle once without claiming interruption',async()=>{
 const f=cancelFixture();
 const result=await f.invoke([{method:'download.cancel',downloadId}]);
 assert.equal(f.cancellations(),1);assert.equal(result.failure,null);
 assert.equal(result.effectStarted,true);assert.equal(result.completedEffect,true);assert.equal(result.inputReleased,true);
 assert.deepEqual(JSON.parse(JSON.stringify(result.completed[0].receipt)),{downloadId,source:'native_download',cancelReturned:true});
 assert.equal(f.row.state,'pending','cancel return does not manufacture a terminal download state');
});
test('cancel refuses unknown, finished, Fetch and foreign Page handles before an SDK effect',async()=>{
 for(const setup of [{state:'completed'},{state:'interrupted'},{source:'fetch'},{rowLabel:'p2'},{handleLabel:'p2'},{}]){
  const f=cancelFixture(setup);if(Object.keys(setup).length===0)f.context.mascDownloads.handles.clear();
  for(const prior of [false,true]){
   const steps=prior?[{method:'fill',selector:'#editor',text:'changed'}]:[];
   const result=await f.invoke([...steps,{method:'download.cancel',downloadId},{method:'click',selector:'#never'}]);
   assert.equal(f.cancellations(),0);assert.equal(result.failure.method,'downloadPreflight');
   assert.equal(result.failure.index,steps.length);assert.equal(result.completed.length,steps.length);
   assert.equal(result.effectStarted,prior);assert.equal(result.completedEffect,prior);
   assert.equal(f.calls.some(call=>call[0]==='click'||call[0]==='snapshot'),false);
  }
 }
});
test('a natural completion winning native cancellation remains completed',async()=>{
 const f=cancelFixture({cancel:async row=>{row.state='completed';}});
 const result=await f.invoke([{method:'download.cancel',downloadId}]);
 assert.equal(f.cancellations(),1);assert.equal(result.failure,null);
 assert.equal(f.row.state,'completed');assert.equal(result.completed[0].receipt.cancelReturned,true);
});
test('a lost native cancellation result retains uncertainty and stops without retry',async()=>{
 const f=cancelFixture({cancel:async()=>{throw Error('native cancellation answer lost');}});
 const result=await f.invoke([{method:'download.cancel',downloadId},{method:'click',selector:'#never'}]);
 assert.equal(f.cancellations(),1);assert.equal(result.failure.method,'download.cancel');
 assert.equal(result.effectStarted,true);assert.equal(result.completedEffect,false);assert.equal(result.completed.length,0);
 assert.deepEqual(f.calls,['url']);
});
test('URL regex waits pass native RegExp and unchanged options to the SDK',async()=>{
 for(const urlRegex of [{source:'^HTTPS://FIXTURE\\.TEST/(start|done)$',flags:'i'},
  {source:''},{source:'start',flags:'g'}]){
  const f=fixture();let waits=0;
  f.page.waitForURL=async(matcher,options)=>{
   waits++;assert.equal(Object.prototype.toString.call(matcher),'[object RegExp]');
   assert.equal(matcher.source,new RegExp(urlRegex.source,urlRegex.flags).source);
   assert.equal(matcher.flags,urlRegex.flags??'');assert.equal(matcher.test(initial),true);
   assert.deepEqual(JSON.parse(JSON.stringify(options)),{timeout:0});
  };
  const result=await run(f.page,request([{method:'waitForURL',urlRegex,options:{timeout:0}},
   {method:'fill',selector:'#editor',text:'changed'}]));
  assert.equal(waits,1);assert.equal(result.failure,null);
  assert.equal(result.completed[0].method,'waitForURL');
  assert.equal(result.completed[1].method,'fill');
  assert.equal(f.calls.filter(call=>call[0]==='snapshot').length,1);
 }
});
test('invalid native URL regex stops before SDK entry and preserves any earlier effect',async()=>{
 for(const urlRegex of [{source:'['},{source:'x',flags:'ii'},{source:'x',flags:'z'},{source:'x',flags:'uv'}]){
  for(const prior of [false,true]){
   const f=fixture();let waits=0;
   f.page.waitForURL=async()=>{waits++;throw Error('must not enter native wait');};
   const prefix=prior?[{method:'fill',selector:'#editor',text:'changed'}]:[];
   const result=await run(f.page,request([...prefix,{method:'waitForURL',urlRegex},
    {method:'click',selector:'#never'}]));
   assert.equal(waits,0);assert.equal(result.failure.method,'waitForURL');
   assert.equal(result.failure.index,prefix.length);assert.equal(result.completed.length,prefix.length);
   assert.equal(result.effectStarted,prior);assert.equal(result.completedEffect,prior);
   assert.equal(result.inputReleased,true);
   assert.equal(f.calls.some(call=>call[0]==='snapshot'||call[0]==='click'),false);
  }
 }
});
test('native navigation timeouts preserve committed state and stop without replay',async()=>{
 for(const waitUntil of ['commit','domcontentloaded','load','networkidle']){
  for(const committed of [false,true]){
   const f=fixture();let navigations=0;
   const native={code:'EGO_NAVIGATION_TIMEOUT',timeoutMs:5000,committed,waitUntil,
    ...(committed?{url:destination,readyState:'interactive'}:{})};
   f.page.goto=async()=>{navigations++;throw Object.assign(Error('native navigation timeout'),native);};
   const result=await run(f.page,request([{method:'fill',selector:'#editor',text:'changed'},
    {method:'goto',url:destination,options:{waitUntil}},{method:'click',selector:'#never'}]));
   assert.deepEqual(JSON.parse(JSON.stringify(result.failure.nativeError)),native);
   assert.equal(navigations,1);assert.equal(result.failure.index,1);assert.equal(result.failure.method,'goto');
   assert.equal(result.completed.length,1);assert.equal(result.completed[0].method,'fill');
   assert.equal(result.effectStarted,true);assert.equal(result.completedEffect,true);
   assert.equal(f.calls.some(call=>call[0]==='click'||call[0]==='snapshot'),false);
  }
 }
});
test('native navigation commit observations do not settle interrupted input',async()=>{
 const f=fixture();let clicks=0;
 f.page.click=async()=>{clicks++;throw Object.assign(Error('native navigation timeout during input'),{
  code:'EGO_NAVIGATION_TIMEOUT',timeoutMs:0,committed:true,waitUntil:'load',url:destination});};
 const result=await run(f.page,request([{method:'click',selector:'#first'},{method:'fill',selector:'#never',text:'changed'}]));
 assert.equal(clicks,1);assert.equal(result.inputReleased,false);
 assert.equal(result.effectStarted,true);assert.equal(result.completedEffect,false);
 assert.equal(result.failure.nativeError.committed,true);assert.equal(result.completed.length,0);
 assert.deepEqual(f.calls,['url']);
});
test('native evaluation timeout diagnostics preserve uncertainty and completed prefix',async()=>{
 for(const [executionStopped,pageResponsive] of [[false,true],[true,true],[false,false]]){
  const f=fixture();let evaluations=0;
  const nativeError={code:'EGO_PAGE_EVALUATION_TIMED_OUT',timeoutMs:14000,
   executionStopped,mayHaveLateEffects:true,pageResponsive};
  f.page.evaluate=async()=>{evaluations++;throw Object.assign(Error('native evaluation safety timeout'),nativeError);};
  const result=await run(f.page,request([{method:'fill',selector:'#editor',text:'changed'},
   {method:'evaluate',source:'window.slow()'},{method:'click',selector:'#next'}]));
  assert.deepEqual(JSON.parse(JSON.stringify(result.failure.nativeError)),nativeError);
  assert.equal(result.failure.index,1);assert.equal(result.failure.method,'evaluate');
  assert.equal(result.completed.length,1);assert.equal(result.completed[0].method,'fill');
  assert.equal(result.effectStarted,true);assert.equal(result.completedEffect,true);
  assert.equal(evaluations,1);assert.equal(f.calls.some(call=>call[0]==='click'||call[0]==='snapshot'),false);
 }
});
test('native stopped-execution diagnostics do not settle held input',async()=>{
 const f=fixture();let clicks=0;
 f.page.click=async()=>{clicks++;throw Object.assign(Error('native locator evaluation timed out'),{
  code:'EGO_PAGE_EVALUATION_TIMED_OUT',timeoutMs:15000,executionStopped:true,
  mayHaveLateEffects:true,pageResponsive:true});};
 const result=await run(f.page,request([{method:'click',selector:'#first'},
  {method:'fill',selector:'#editor',text:'must not run'}]));
 assert.equal(clicks,1);assert.equal(result.inputReleased,false);
 assert.equal(result.effectStarted,true);assert.equal(result.completedEffect,false);
 assert.equal(result.completed.length,0);assert.equal(result.failure.nativeError.executionStopped,true);
 assert.deepEqual(f.calls,['url']);
});
test('ordinary error messages never manufacture native timeout diagnostics',async()=>{
 for(const message of ['EGO_PAGE_EVALUATION_TIMED_OUT executionStopped=true','EGO_NAVIGATION_TIMEOUT committed=true']){
 const f=fixture();
 f.page.evaluate=async()=>{throw Error(message);};
 const result=await run(f.page,request([{method:'evaluate',source:'window.slow()'}]));
 assert.equal(Object.hasOwn(result.failure,'nativeError'),false);
 assert.equal(result.effectStarted,true);assert.equal(result.completedEffect,false);
 }
});
test('native Page observations, snapshot options and explicit waits retain values',async()=>{
 const f=fixture();let events=[{method:'Page.loadEventFired',params:{timestamp:1}}];
 f.page.info=async()=>({url:initial,title:'Fixture',w:800,h:600});
 f.page.events=async()=>{const result=events;events=[];return result;};
 f.page.waitForTimeout=async milliseconds=>f.calls.push(['waitForTimeout',milliseconds]);
 const options={scope:'subtree',root:'@21',includeActionMarks:false,includeStableLocator:true};
 const result=await run(f.page,request([
  {method:'url'},{method:'title'},{method:'info'},
  {method:'snapshot',options},{method:'waitForTimeout',milliseconds:0.5},
  {method:'events'},{method:'events'},
 ]));
 assert.equal(result.failure,null);
 assert.equal(result.completed[0].receipt,initial);
 assert.equal(result.completed[1].receipt,'Fixture');
 assert.equal(result.completed[2].receipt.w,800);
 assert.equal(result.completed[3].receipt,'native result');
 assert.equal(result.completed[4].receipt,null);
 assert.equal(result.completed[5].receipt[0].method,'Page.loadEventFired');
 assert.equal(result.completed[6].receipt.length,0);
 assert.equal(result.effectStarted,true);assert.equal(result.completedEffect,true);
 assert.deepEqual(f.calls.find(call=>call[0]==='snapshot')[1],options);
 assert.deepEqual(f.calls.find(call=>call[0]==='waitForTimeout'),['waitForTimeout',0.5]);
});
test('a lost event drain stays uncertain and stops following input',async()=>{
 const f=fixture();let drains=0;
 f.page.events=async()=>{drains++;throw Error('lost after drain');};
 const result=await run(f.page,request([{method:'events'},{method:'click',selector:'#next'}]));
 assert.equal(drains,1);assert.equal(result.effectStarted,true);assert.equal(result.completedEffect,false);
 assert.equal(result.failure.method,'events');assert.equal(result.completed.length,0);
 assert.equal(f.calls.some(call=>call[0]==='click'),false);
});
test('pure native observations stay read-only and stop on a dialog',async()=>{
 const f=fixture();
 const pure=await run(f.page,request([{method:'url'},{method:'title'},{method:'info'},{method:'snapshot'}]));
 assert.equal(pure.failure,null);assert.equal(pure.effectStarted,false);assert.equal(pure.completedEffect,false);
 f.page.info=async()=>({dialog:{type:'prompt',message:'answer me'}});
 const blocked=await run(f.page,request([{method:'info'},{method:'click',selector:'#next'}]));
 assert.equal(blocked.failure.dialog.type,'prompt');assert.equal(blocked.effectStarted,false);
 assert.equal(blocked.completed.length,1);assert.equal(f.calls.some(call=>call[0]==='click'),false);
});
test('malformed native observation values stop before following input',async()=>{
 for(const [method,bad] of [['url',null],['title',42],['info',[]],['snapshot',{}],['events',null]]){
  const f=fixture();let reads=0;
  f.page[method]=async()=>method==='url'&&reads++===0?initial:bad;
  const result=await run(f.page,request([{method},{method:'click',selector:'#next'}]));
  assert.equal(result.failure.method,method);assert.equal(result.completed.length,0);
  assert.equal(result.effectStarted,method==='events');
  assert.equal(f.calls.some(call=>call[0]==='click'),false);
 }
});
test('native action, navigation, mouse and selection options survive unchanged',async()=>{
 const f=fixture();const native=[];
 f.page.mouse={};
 for (const method of ['click','move','wheel','up'])
  f.page.mouse[method]=async(...args)=>{native.push([method,...args]);return {};};
 f.page.reload=async(options)=>{native.push(['reload',options]);return {};};
 const result=await run(f.page,request([
  {method:'click',selector:'#button',options:{button:'right',clickCount:2,delay:0.5,position:{x:2,y:3},force:false,label:'Open row context menu'}},
  {method:'fill',selector:'#editor',text:'changed',options:{clearFirst:false}},
  {method:'press',selector:'#editor',key:'Enter',options:{delay:2}},
  {method:'selectOption',selector:'#select',selectionJson:'{"label":"Disabled B"}'},
  {method:'selectOption',selector:'#select',selectionJson:'null'},
  {method:'goto',url:destination,options:{referer:initial,waitUntil:'commit'}},
  {method:'reload',options:{waitUntil:'domcontentloaded'}},
  {method:'waitForLoadState',options:{idleMs:0}},
  {method:'mouse.move',x:40,y:50,options:{steps:3,label:'Point at result panel'}},
  {method:'mouse.click',x:40,y:50,options:{button:'middle',delay:3}},
  {method:'mouse.wheel',x:0,y:120,options:{label:'Read next result rows'}},
  {method:'dragAndDrop',selector:'#source',destination:'#target',options:{button:'right',sourcePosition:{x:1,y:2},targetPosition:{x:3,y:4},force:true,timeout:9000}},
 ]));
 assert.equal(result.failure,null);assert.equal(result.inputReleased,true);
 const click=f.calls.find(call=>call[0]==='click');
 assert.equal(click[2].button,'right');assert.equal(click[2].clickCount,2);assert.equal(click[2].delay,0.5);
 assert.deepEqual(click[2].position,{x:2,y:3});assert.equal(click[2].force,false);
 assert.equal(click[2].label,'MASC · fixture · workflow · Open row context menu');
 assert.equal(f.calls.find(call=>call[0]==='fill')[3].clearFirst,false);
 assert.equal(f.calls.find(call=>call[0]==='press')[3].delay,2);
 const selections=f.calls.filter(call=>call[0]==='selectOption');
 assert.equal(selections[0][2].label,'Disabled B');assert.equal(selections[1][2],null);
 assert.equal(f.calls.find(call=>call[0]==='goto')[2].referer,initial);
 assert.equal(f.calls.find(call=>call[0]==='goto')[2].waitUntil,'commit');
 assert.equal(f.calls.find(call=>call[0]==='waitForLoadState')[1],undefined);
 assert.equal(f.calls.find(call=>call[0]==='waitForLoadState')[2].idleMs,0);
 assert.equal(native.find(call=>call[0]==='move')[3].steps,3);
 assert.equal(native.find(call=>call[0]==='click')[3].button,'middle');
 const drag=f.calls.find(call=>call[0]==='dragAndDrop');
 assert.equal(drag[2],'#target');assert.equal(drag[3].button,'right');assert.equal(drag[3].timeout,9000);
 assert.deepEqual(drag[3].sourcePosition,{x:1,y:2});
});
test('a drag interrupted by a dialog preserves uncertain input ownership',async()=>{
 const f=fixture();let later=0;
 f.page.dragAndDrop=async()=>({dialog:{type:'alert',message:'hold'}});
 f.page.mouse={up:async()=>{later++;}};
 const result=await run(f.page,request([
  {method:'dragAndDrop',selector:'#source',destination:'#target'},
  {method:'click',selector:'#submit'},
 ]));
 assert.equal(result.inputReleased,false);assert.equal(result.completedEffect,true);
 assert.equal(result.completed.length,1);assert.equal(result.failure.dialog.type,'alert');
 assert.equal(later,0,'a blocking dialog is handed back before further input');
});
test('lost pointer input never treats SDK cleanup void as a release acknowledgement',async()=>{
 for (const method of ['click','dblclick','mouse.click','dragAndDrop']) {
  const f=fixture();let down=false,releases=0,later=0;
  const click=async()=>{down=true;throw Error('lost click response');};
  f.page.mouse={click,up:async options=>{
   releases++;assert.equal(options.button,'right');
   // The actual SDK can return void after a dialog interrupted this release.
  }};
  if(method!=='mouse.click')f.page[method]=click;
  f.page.fill=async()=>{later++;};
  const result=await run(f.page,request([
   {method,selector:'#source',destination:'#target',x:20,y:30,options:{button:'right',delay:25}},
   {method:'fill',selector:'#editor',text:'never'},
  ]));
  assert.equal(releases,0);assert.equal(down,true);assert.equal(later,0);
  assert.equal(result.inputReleased,false);assert.equal(result.completed.length,0);
  assert.equal(result.failure.index,0);
 }
});
test('lost key input preserves unconfirmed release without guessing which keys to send',async()=>{
 for (const method of ['press','keyboard.press','keyboard.type','keyboard.paste']) {
  const f=fixture();let entries=0,releases=0,later=0;
  const input=async()=>{entries++;throw Error('lost key input response');};
  f.page.keyboard={press:input,type:input,paste:input,up:async()=>{releases++;}};
  f.page.press=input;f.page.mouse={up:async()=>{releases++;}};
  f.page.fill=async()=>{later++;};
  const result=await run(f.page,request([
   {method,selector:'#editor',key:'ControlOrMeta+Enter',text:'x',options:{delay:25}},
   {method:'fill',selector:'#editor',text:'never'},
  ]));
  assert.equal(entries,1);assert.equal(releases,0);assert.equal(later,0);
  assert.equal(result.inputReleased,false);assert.equal(result.completed.length,0);
 }
});
test('receipt-less holding input keeps release uncertain on dialog or failed observation',async()=>{
 for (const method of ['keyboard.type','keyboard.press','keyboard.paste','press','click','dblclick','mouse.click','dragAndDrop']) {
  for (const observationFails of [false,true]) {
   const f=fixture();const input=async()=>{};
   f.page.keyboard={type:input,press:input,paste:input};f.page.mouse={click:input};
   if(!method.includes('.'))f.page[method]=input;
   f.page.info=async()=>{if(observationFails)throw Error('lost observation');return {dialog:{type:'alert',message:'hold'}};};
   const result=await run(f.page,request([{method,selector:'#editor',destination:'#target',key:'Enter',text:'x',x:20,y:30}]));
   assert.equal(result.inputReleased,false,method);
   assert.equal(result.completed.length,0);assert.equal(result.completedEffect,false);
   assert.equal(result.failure.method,method);
  }
 }
});
test('void holding input never infers release from a clear or rapidly closed dialog',async()=>{
 for (const method of ['keyboard.type','keyboard.press','keyboard.paste','press','click','dblclick','mouse.click','dragAndDrop']) {
  for (const dialogWasClosed of [false,true]) {
   const f=fixture();let entered=0,later=0,held=false,dialog=null;
   const input=async()=>{entered++;held=true;if(dialogWasClosed){dialog={type:'alert'};dialog=null;}};
   f.page.keyboard={type:input,press:input,paste:input};f.page.mouse={click:input};
   if(!method.includes('.'))f.page[method]=input;
   f.page.info=async()=>({dialog});
   f.page.fill=async()=>{later++;};
   const result=await run(f.page,request([
    {method,selector:'#editor',destination:'#target',key:'Enter',text:'x',x:20,y:30},
    {method:'fill',selector:'#next',text:'must not run'},
   ]));
   assert.equal(entered,1);assert.equal(held,true);
   assert.equal(later,0,method+' cannot continue on an absent action receipt');
   assert.equal(result.inputReleased,false);assert.equal(result.effectStarted,true);
   assert.equal(result.completedEffect,false);assert.equal(result.completed.length,0);
   assert.equal(result.failure.index,0);assert.equal(result.failure.method,method);
   assert.equal(f.calls.some(call=>call[0]==='snapshot'),false);
  }
 }
});
test('a void holding step retains the earlier completed prefix without replay',async()=>{
 const f=fixture();let typed=0,later=0;
 f.page.keyboard={async type(){typed++;}};f.page.click=async()=>{later++;return {};};
 const result=await run(f.page,request([
  {method:'fill',selector:'#editor',text:'prefix'},
  {method:'keyboard.type',text:'may be partial'},
  {method:'click',selector:'#submit'},
 ]));
 assert.equal(typed,1);assert.equal(later,0);
 assert.equal(result.completed.length,1);assert.equal(result.completed[0].method,'fill');
 assert.equal(result.completedEffect,true);assert.equal(result.inputReleased,false);
 assert.equal(result.failure.index,1);assert.equal(result.failure.method,'keyboard.type');
});
test('a missing press selector stops before input while a later press failure stays uncertain',async()=>{
 for(const missing of [false,true]) {
  const f=fixture();let pressed=0,later=0;
  f.page.waitForSelector=async(selector,options)=>{
   assert.equal(selector,'#editor');assert.equal(options.state,'attached');
   assert.equal(options.timeout,37);assert.equal(Object.hasOwn(options,'delay'),false);
   if(missing)throw Error('selector absent');
  };
  f.page.press=async()=>{pressed++;throw Error('press reply lost');};
  f.page.fill=async()=>{later++;};
  const result=await run(f.page,request([
   {method:'press',selector:'#editor',key:'Enter',options:{timeout:37,delay:2}},
   {method:'fill',selector:'#editor',text:'not sent'},
  ]));
  assert.equal(pressed,missing?0:1);assert.equal(later,0);
  assert.equal(result.failure.method,missing?'inputPreflight':'press');
  assert.equal(result.effectStarted,!missing);assert.equal(result.inputReleased,missing);
  assert.equal(result.completed.length,0);
 }
});
test('Page code receives JSON in the browser context and never runs as Node source',async()=>{
 const f=fixture();const browser=vm.createContext({document:{title:'browser only'}});
 f.page.evaluate=async function(expression){
  assert.equal(arguments.length,1,'SDK string expressions reject even an explicit undefined argument');
  f.calls.push(['evaluate',expression]);return vm.runInContext(expression,browser);
 };
 f.page.waitForFunction=async function(expression,input,options){
  assert.equal(input,undefined);assert.equal(options.timeout,300);assert.equal(options.polling,7);
  assert.equal(vm.runInContext(expression,browser),true);return true;
 };
 const argument=JSON.stringify({text:'\");globalThis.hostEscaped=true;//\n한글 😀'});
 const result=await run(f.page,request([
  {method:'evaluate',source:'value => ({title:document.title,text:value.text,host:typeof process,dialog:"app data"})',argumentJson:argument},
  {method:'waitForFunction',source:'value => document.title === value',argumentJson:'"browser only"',options:{timeout:300,polling:7}},
  {method:'evaluate',source:'document.title'},
  {method:'evaluate',source:'value => ({own:Object.hasOwn(value,"__proto__"),plain:Object.getPrototypeOf(value)===Object.prototype,data:value.__proto__.polluted})',argumentJson:'{"__proto__":{"polluted":true}}'},
 ]));
 assert.equal(result.failure,null);assert.equal(result.completed.length,4);
 assert.equal(result.completed[0].receipt.text,JSON.parse(argument).text);
 assert.equal(result.completed[0].receipt.host,'undefined');
 assert.equal(result.completed[0].receipt.dialog,'app data','application fields are not native dialog receipts');
 assert.equal(result.completed[2].receipt,'browser only');
 assert.equal(result.completed[3].receipt.own,true);
 assert.equal(result.completed[3].receipt.plain,true);
 assert.equal(result.completed[3].receipt.data,true);
 assert.equal(vm.runInContext('typeof hostEscaped',browser),'undefined');
 assert.equal(result.effectStarted,true);assert.equal(result.completedEffect,true);
});
test('native fetch forwards browser options and returns HTTP errors as data',async()=>{
 const f=fixture();let observed;
 f.page.fetch=async(url,options)=>{observed={url,options};return {ok:false,status:409,body:'existing'};};
 const fetchOptions={method:'POST',headers:{'Content-Type':'text/plain'},body:'한글 😀',credentials:'same-origin',cache:'no-store'};
 const result=await run(f.page,request([{method:'fetch',url:'https://fixture.test/data',options:{...fetchOptions,timeout:400}}]));
 assert.equal(result.failure,null);assert.equal(result.completed[0].receipt.status,409);
 assert.equal(observed.url,'https://fixture.test/data');assert.equal(observed.options.timeout,400);
 assert.equal(observed.options.body,'한글 😀');assert.deepEqual(observed.options.headers,fetchOptions.headers);
 assert.equal(result.completedEffect,true);
});
function savedFetchFixture() {
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'masc-fetch-test-'));
 const context=vm.createContext({crypto});
 const execute=vm.runInContext('('+source+')',context);
 const f=fixture();
 return {...f,directory,context,
  run:steps=>execute(f.page,{...request(steps),downloads:directory,label:'p1'}),
  close:()=>fs.rmSync(directory,{recursive:true,force:true})};
}
const savedMetadata=(savedPath,extra={})=>({ok:true,status:200,statusText:'OK',
 url:'https://fixture.test/data',headers:{'content-type':'application/octet-stream'},savedPath,...extra});
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
function writeSavedFile(f,savedPath,bytes) {
 assert.equal(path.dirname(savedPath),f.directory,'SDK writes only inside this test-owned directory');
 assert.match(path.basename(savedPath),uuid);
 fs.writeFileSync(savedPath,bytes);
}
test('saved native fetch writes binary bytes to a generated path and returns artifact provenance',async()=>{
 const f=savedFetchFixture();const bytes=Buffer.from([0,255,128,13,10,0,65]);
 const paths=[];
 try {
  for(const metadata of [{ok:true,status:200,statusText:'OK',url:'https://fixture.test/data'},
    {ok:false,status:404,statusText:'Not Found',url:'https://fixture.test/missing'},
    {ok:false,status:0,statusText:'',url:''}]) {
   const name='한글 binary 404.bin';
   const options={saveAs:name,method:'POST',body:'native body',credentials:'include',mode:'cors',redirect:'follow',timeout:41};
   let calls=0;
   f.page.fetch=async(url,actual)=>{
    calls++;assert.equal(url,'/api/binary');
    assert.equal(path.dirname(actual.saveAs),f.directory);
    assert.match(path.basename(actual.saveAs),uuid);
    assert.notEqual(path.basename(actual.saveAs),name);
    assert.deepEqual({...actual,saveAs:name},options);
    paths.push(actual.saveAs);writeSavedFile(f,actual.saveAs,bytes);
    return savedMetadata(actual.saveAs,metadata);
   };
   const result=await f.run([{method:'fetch',url:'/api/binary',options}]);
   assert.equal(result.failure,null);assert.equal(calls,1);
   assert.equal(result.effectStarted,true);assert.equal(result.completedEffect,true);
   const receipt=result.completed[0].receipt;
   assert.deepEqual(Object.keys(receipt).sort(),['downloadId','headers','ok','source','status','statusText','suggestedFilename','url'].sort());
   assert.equal(receipt.source,'fetch');assert.equal(receipt.suggestedFilename,name);
   assert.equal(receipt.status,metadata.status);assert.equal(receipt.ok,metadata.ok);
   assert.equal(receipt.url,metadata.url);assert.match(receipt.downloadId,uuid);
   const row=f.context.mascDownloads.rows.at(-1);
   assert.equal(row.id,receipt.downloadId);assert.equal(path.basename(row.path),row.id);
   assert.equal(row.label,'p1');assert.equal(row.source,'fetch');assert.equal(row.state,'completed');
   assert.equal(row.suggestedFilename,name);assert.equal(row.url,metadata.url);assert.equal(row.reason,null);
   assert.deepEqual(fs.readFileSync(row.path),bytes);
   assert.equal(options.saveAs,name,'the requested artifact name remains caller data');
  }
  assert.equal(new Set(paths).size,3,'each save has a separate generated file');
  assert.equal(f.context.mascDownloads.rows.length,3);
 } finally {f.close();}
});
test('a failed or forged saved fetch retains its partial file and stops without retry',async()=>{
 const invalid=[
  ()=>{throw Error('native fetch response lost');},
  actual=>savedMetadata(path.join(path.dirname(actual),'foreign.bin')),
  actual=>{const receipt=savedMetadata(actual);delete receipt.savedPath;return receipt;},
  actual=>({...savedMetadata(actual),body:'unexpected SDK save metadata'}),
  actual=>savedMetadata(actual,{ok:'true'}),
  actual=>savedMetadata(actual,{status:'200'}),
  actual=>savedMetadata(actual,{statusText:null}),
  actual=>savedMetadata(actual,{url:null}),
  actual=>savedMetadata(actual,{headers:{'x-test':3}}),
 ];
 for(const answer of invalid) {
  const f=savedFetchFixture();let calls=0,actualPath;
  try {
   f.page.fetch=async(_url,options)=>{calls++;actualPath=options.saveAs;
    writeSavedFile(f,actualPath,Buffer.from([0,255,1]));return answer(actualPath);};
   const result=await f.run([{method:'fetch',url:'/api/binary',options:{saveAs:'retained.bin'}},
    {method:'click',selector:'#must-not-replay'}]);
   assert.equal(calls,1);assert.equal(result.failure.method,'fetch');
   assert.equal(result.completed.length,0);assert.equal(result.effectStarted,true);assert.equal(result.completedEffect,false);
   assert.equal(f.calls.some(call=>call[0]==='click'),false);
   const row=f.context.mascDownloads.rows[0];
   assert.equal(row.state,'interrupted');assert.equal(row.path,null);assert.equal(row.source,'fetch');
   assert.equal(row.label,'p1');assert.equal(row.suggestedFilename,'retained.bin');
   assert.equal(typeof row.reason,'string');assert.notEqual(row.reason.length,0);
   assert.deepEqual(fs.readFileSync(actualPath),Buffer.from([0,255,1]));
  } finally {f.close();}
 }
});
test('a completed saved fetch remains recoverable after a later step or final snapshot fails',async()=>{
 for(const later of ['step','snapshot']) {
  const f=savedFetchFixture();let calls=0;
  try {
   f.page.fetch=async(_url,options)=>{calls++;writeSavedFile(f,options.saveAs,Buffer.from([1,0,255]));return savedMetadata(options.saveAs);};
   if(later==='step')f.page.waitForURL=async()=>{throw Error('later wait failed');};
   else f.page.snapshot=async()=>{throw Error('final snapshot failed');};
   const steps=[{method:'fetch',url:'/api/binary',options:{saveAs:'complete.bin'}}];
   if(later==='step')steps.push({method:'waitForURL',url:destination});
   const result=await f.run(steps);
   assert.equal(calls,1);assert.equal(result.failure.method,later==='step'?'waitForURL':'snapshot');
   assert.equal(result.completed.length,1);assert.equal(result.completedEffect,true);
   const row=f.context.mascDownloads.rows[0];
   assert.equal(row.id,result.completed[0].receipt.downloadId);assert.equal(row.state,'completed');
   assert.equal(row.source,'fetch');assert.equal(row.reason,null);
   assert.deepEqual(fs.readFileSync(row.path),Buffer.from([1,0,255]));
  } finally {f.close();}
 }
});
test('Page execution and state predicates can have effects before an uncertain failure',async()=>{
 for (const method of ['evaluate','waitForFunction','fetch']) {
  const f=fixture();let entries=0;
  f.page[method]=async()=>{entries++;throw Error('lost '+method+' result');};
  const result=await run(f.page,request([
   {method,source:'window.state = 1',url:'https://fixture.test/data'},
   {method:'click',selector:'@12'},
  ]));
  assert.equal(entries,1);assert.equal(result.failure.index,0);
  assert.equal(result.effectStarted,true);assert.equal(result.completedEffect,false);
  assert.equal(result.completed.length,0);assert.equal(f.calls.some(call=>call[0]==='click'),false);
 }
});
test('known native sequence navigates, waits and returns one final snapshot',async()=>{
 const f=fixture();const result=await run(f.page,request([
  {method:'click',selector:'@12'},
  {method:'waitForURL',url:destination},
  {method:'fill',selector:'loc=css:#editor',text:'changed'},
  {method:'waitForSelector',selector:'loc=css:#ready',state:'visible',options:{timeout:90}},
  {method:'waitForLoadState',state:'load'},
 ]));
 assert.equal(result.failure,null);assert.equal(result.url,destination);assert.equal(result.snapshot,'native result');
 assert.equal(result.completed.length,5);assert.equal(result.completedEffect,true);
 assert.equal(f.calls.filter(c=>Array.isArray(c)&&c[0]==='snapshot').length,1);
 assert.equal(f.calls.find(c=>Array.isArray(c)&&c[0]==='snapshot')[1],undefined,'viewport uses the SDK default, not a MASC scope name');
 assert.equal(f.calls[2][0],'waitForURL');
 assert.equal(f.calls[4][2].timeout,90);assert.equal(f.calls[4][2].state,'visible');
 assert.equal(Object.hasOwn(f.calls[1][2],'timeout'),false,'SDK defaults are not replaced');
});
test('full-page workflow snapshot uses the native full_page scope',async()=>{
 const f=fixture();const result=await run(f.page,{...request([]),snapshotScope:'full_page'});
 assert.equal(result.failure,null);
 assert.equal(f.calls.find(c=>Array.isArray(c)&&c[0]==='snapshot')[1].scope,'full_page');
});
test('a failed SDK wait retains prior effects and never runs later steps',async()=>{
 const f=fixture({fail:'waitForURL'});const result=await run(f.page,request([
  {method:'click',selector:'@12'},{method:'waitForURL',url:destination},{method:'press',selector:'#editor',key:'Enter'},
 ]));
 assert.equal(result.failure.index,1);assert.equal(result.completed.length,1);assert.equal(result.completedEffect,true);
 assert.deepEqual(f.calls.map(c=>typeof c==='string'?c:c[0]),['url','click','waitForURL']);
});
test('an SDK input error stays uncertain and is never retried',async()=>{
 const f=fixture({fail:'fill'});const result=await run(f.page,request([{method:'fill',selector:'@4',text:'private'},{method:'click',selector:'@5'}]));
 assert.equal(result.effectStarted,true);assert.equal(result.completedEffect,false);assert.equal(result.completed.length,0);
 assert.equal(result.failure.index,0);assert.deepEqual(f.calls.map(c=>typeof c==='string'?c:c[0]),['url','fill']);
});
test('a failed read-only wait has no input effect',async()=>{
 const f=fixture({fail:'waitForSelector'});const result=await run(f.page,request([{method:'waitForSelector',selector:'@4',state:'visible'}]));
 assert.equal(result.effectStarted,false);assert.equal(result.completedEffect,false);
 assert.equal(result.failure.method,'waitForSelector');
});
test('dialog or SDK control loss stops the sequence without follow-up reads',async()=>{
 const f=fixture({dialog:true});const result=await run(f.page,request([{method:'click',selector:'@4'},{method:'fill',selector:'@5',text:'private'}]));
 assert.equal(result.completed.length,1);assert.equal(result.failure.dialog.message,'hold');
 assert.deepEqual(f.calls.map(c=>typeof c==='string'?c:c[0]),['url','click']);
 const lost=fixture({fail:'click'});const stopped=await run(lost.page,request([{method:'click',selector:'@4'},{method:'goto',url:destination}]));
 assert.equal(stopped.completed.length,0);assert.deepEqual(lost.calls.map(c=>typeof c==='string'?c:c[0]),['url','click']);
});
test('wrong starting URL refuses before input and final snapshot cuts preserve Unicode',async()=>{
 const f=fixture();const wrong=await run(f.page,{...request([{method:'click',selector:'@1'}]),expectedUrl:destination});
 assert.equal(wrong.effectStarted,false);assert.deepEqual(f.calls,['url']);
 const unicode=fixture({snapshot:'a😀b'});const result=await run(unicode.page,{...request([]),maxChars:2});
 assert.equal(result.snapshot,'a');assert.equal(result.chars,4);assert.equal(result.truncated,true);
});

test('SDK owns omitted timeouts and settlement; explicit timeouts are unchanged',async()=>{
 const f=fixture();let release,entered;
 const gate=new Promise(resolve=>{release=resolve;});
 const started=new Promise(resolve=>{entered=resolve;});
 f.page.fill=async(...args)=>{f.calls.push(['fill',...args]);entered();await gate;return {};};
 const pending=run(f.page,request([
  {method:'fill',selector:'@1',text:'changed'},
  {method:'hover',selector:'@2',options:{timeout:75000}},
  {method:'waitForLoadState',state:'load',options:{timeout:0}},
 ]));
 await started;
 assert.deepEqual(f.calls.map(c=>typeof c==='string'?c:c[0]),['url','fill']);
 assert.equal(Object.hasOwn(f.calls[1][3],'timeout'),false,'omission delegates the default to Ego');
 release();const result=await pending;
 assert.equal(result.failure,null);assert.equal(result.completed.length,3);
 assert.equal(f.calls.find(c=>Array.isArray(c)&&c[0]==='hover')[2].timeout,75000);
 assert.equal(f.calls.find(c=>Array.isArray(c)&&c[0]==='waitForLoadState')[2].timeout,0);
});

test('native rich input keeps focus, clipboard content and keyboard signatures',async()=>{
 const f=fixture();let focused=false,value='',html='';
 f.page.focus=async(selector,options)=>{assert.equal(selector,'#editor');assert.equal(options.timeout,0);focused=true;};
 f.page.keyboard={
  async type(text,options){assert.equal(arguments.length,2);assert.equal(options.delay,4);assert.ok(focused);value+=text;},
  async insertText(text){assert.equal(arguments.length,1);assert.ok(focused);value+=text;},
  async paste(content){assert.equal(arguments.length,1);assert.ok(focused);value+=content.text;html=content.html;return {};},
  async press(key,options){assert.equal(arguments.length,2);assert.equal(options.delay,5);assert.equal(key,'ControlOrMeta+A');return {};},
 };
 f.page.reload=async(options)=>{assert.equal(options.timeout,7000);return {};};
 const typed=await run(f.page,request([
  {method:'focus',selector:'#editor',options:{timeout:0}},
  {method:'keyboard.type',text:'hello ',options:{delay:4}},
  {method:'keyboard.insertText',text:'must not run'},
 ]));
 assert.equal(typed.failure.method,'keyboard.type');assert.equal(typed.inputReleased,false);
 assert.equal(typed.completed.length,1);assert.equal(value,'hello ');
 // A distinct later invocation models only signature forwarding after an
 // external input reset; it does not exercise or authorize that reset.
 const result=await run(f.page,request([
  {method:'keyboard.insertText',text:'한글 😀'},
  {method:'keyboard.paste',text:'Name\tStatus',html:'<table><tr><td>Name</td><td>Status</td></tr></table>'},
  {method:'keyboard.press',key:'ControlOrMeta+A',options:{delay:5}},
  {method:'reload',options:{timeout:7000}},
 ]));
 assert.equal(result.failure,null);assert.equal(value,'hello 한글 😀Name\tStatus');
 assert.equal(html,'<table><tr><td>Name</td><td>Status</td></tr></table>');
 assert.equal(result.completed.length,4);assert.equal(result.completedEffect,true);
});
test('plain paste preserves empty strings and failed keyboard input is never replayed',async()=>{
 const f=fixture();let pasted;
 f.page.keyboard={async paste(content){pasted=content;throw Error('native paste interrupted');}};
 const stopped=await run(f.page,request([
  {method:'keyboard.paste',text:''},{method:'goto',url:destination},
 ]));
 assert.equal(pasted,'');assert.equal(stopped.failure.method,'keyboard.paste');
 assert.equal(stopped.effectStarted,true);assert.equal(stopped.completedEffect,false);
 assert.equal(stopped.completed.length,0);assert.deepEqual(f.calls,['url']);
});
test('receipt-less keyboard input stops on a dialog and retains a settled input on observation loss',async()=>{
 const f=fixture();let inserted=0,later=0;
 f.page.keyboard={async insertText(){inserted++;}};
 f.page.click=async()=>{later++;};
 f.page.info=async()=>({dialog:{type:'alert',message:'input needs an answer'}});
 const input=request([{method:'keyboard.insertText',text:'x'},{method:'click',selector:'#submit'}]);
 const stopped=await run(f.page,input);
 assert.equal(inserted,1);assert.equal(later,0);assert.equal(stopped.completed.length,1);
 assert.equal(stopped.failure.dialog.message,'input needs an answer');
 f.page.info=async()=>{throw Error('page ownership changed');};
 const lost=await run(f.page,input);
 assert.equal(inserted,2);assert.equal(later,0);assert.equal(lost.completed.length,1);
 assert.equal(lost.failure.method,'observation');assert.equal(lost.failure.index,1);
 assert.equal(lost.completedEffect,true);
});
