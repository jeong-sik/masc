const assert=require('node:assert/strict');
const fs=require('node:fs');
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
   if(options!==undefined&&!['full_page','only_within_viewport','subtree'].includes(options.scope))
    throw Error('page.snapshot scope must be one of full_page, only_within_viewport, subtree');
   return snapshot;
  },
 };
 for(const method of ['click','dblclick','hover','fill','press','selectOption','goto','waitForURL','waitForSelector','waitForLoadState'])page[method]=async(...args)=>{
  calls.push([method,...args]);if(method===fail)throw Error('native '+method+' failed');
  if(method==='fill')value=args[1];if(method==='goto'||method==='click')url=destination;
  if(method==='waitForURL')assert.equal(url,args[0]);
  if(method==='waitForSelector')assert.equal(value,'changed');
  return dialog&&method==='click'?{dialog:{type:'alert',message:'hold'}}:method==='selectOption'?['b']:{};
 };
 return {page,calls};
}
const request=steps=>({expectedUrl:initial,steps,snapshotScope:'viewport',maxChars:100,cursor:'MASC · fixture · workflow'});
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
  {method:'waitForFunction',source:'value => document.title === value',argumentJson:'"browser only"',timeoutMs:300,pollingMs:7},
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
 const result=await run(f.page,request([{method:'fetch',url:'https://fixture.test/data',fetchOptions,timeoutMs:400}]));
 assert.equal(result.failure,null);assert.equal(result.completed[0].receipt.status,409);
 assert.equal(observed.url,'https://fixture.test/data');assert.equal(observed.options.timeout,400);
 assert.equal(observed.options.body,'한글 😀');assert.deepEqual(observed.options.headers,fetchOptions.headers);
 assert.equal(result.completedEffect,true);
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
  {method:'waitForSelector',selector:'loc=css:#ready',state:'visible',timeoutMs:90},
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
  {method:'hover',selector:'@2',timeoutMs:75000},
  {method:'waitForLoadState',state:'load',timeoutMs:0},
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
  async type(text){assert.equal(arguments.length,1);assert.ok(focused);value+=text;},
  async insertText(text){assert.equal(arguments.length,1);assert.ok(focused);value+=text;},
  async paste(content){assert.equal(arguments.length,1);assert.ok(focused);value+=content.text;html=content.html;},
  async press(key){assert.equal(arguments.length,1);assert.equal(key,'ControlOrMeta+A');},
 };
 f.page.reload=async(options)=>{assert.equal(options.timeout,7000);return {};};
 const result=await run(f.page,request([
  {method:'focus',selector:'#editor',timeoutMs:0},
  {method:'keyboard.type',text:'hello '},
  {method:'keyboard.insertText',text:'한글 😀'},
  {method:'keyboard.paste',text:'Name\tStatus',html:'<table><tr><td>Name</td><td>Status</td></tr></table>'},
  {method:'keyboard.press',key:'ControlOrMeta+A'},
  {method:'reload',timeoutMs:7000},
 ]));
 assert.equal(result.failure,null);assert.equal(value,'hello 한글 😀Name\tStatus');
 assert.equal(html,'<table><tr><td>Name</td><td>Status</td></tr></table>');
 assert.equal(result.completed.length,6);assert.equal(result.completedEffect,true);
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
