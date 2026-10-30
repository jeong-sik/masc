const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync(require('node:path').join(__dirname,'../lib/browser_ego_peer.ml'),'utf8')
  .match(/let target_input_script = \{js\|([\s\S]*?)\|js\}/)?.[1];
assert.ok(source);
const input = vm.runInNewContext('('+source+')');
const url = 'https://example.test/observed';
const actions = {click:'click',fill:'fill',hover:'hover',double_click:'dblclick',select_option:'selectOption',drag_to:'dragAndDrop'};
function page({redirect=false,failed=false}={}) {
  const calls=[];
  const p={async url(){calls.push('url');return redirect?'https://example.test/other':url;},mouse:{async up(){calls.push('up');}}};
  // No MASC waitForSelector or evaluate: the native method owns actionability.
  for(const method of Object.values(actions))p[method]=async(...args)=>{
    calls.push([method,...args]);if(failed)throw Error('reply lost after native input');
    return method==='selectOption'?['literal-value']:{};
  };
  return {p,calls};
}
const args = action => ({action,target:'@12',destination:'loc=css:#destination',expectedUrl:url,text:'literal " value',selection:{value:'literal-value'},cursor:'MASC · fixture · '+action});
test('refs and SDK locators use native methods without a separate MASC resolver or wait',async()=>{
  for(const [action,method] of Object.entries(actions))for(const target of ['@12','loc=css:#editor','loc=role:button[name="Send"]']) {
    const {p,calls}=page();const request={...args(action),target};const result=await input(p,request);
    assert.equal(result.error,null);assert.equal(result.urlBefore,url);
    assert.equal(calls[1][0],method);assert.equal(calls[1][1],target);assert.equal(calls.length,2);
    if(['click','hover','double_click'].includes(action))assert.deepEqual(JSON.parse(JSON.stringify(calls[1])),[method,target,{label:request.cursor}]);
    if(action==='drag_to')assert.deepEqual(JSON.parse(JSON.stringify(calls[1])),[method,target,request.destination,{label:request.cursor}]);
    if(action==='fill')assert.deepEqual(calls[1],[method,target,'literal " value']);
    if(action==='select_option')assert.deepEqual(JSON.parse(JSON.stringify(result.receipt)),{selectedValues:['literal-value']});
  }
});
test('an observed URL mismatch refuses every action before native input',async()=>{
  for(const action of Object.keys(actions)) {
    const {p,calls}=page({redirect:true});const result=await input(p,args(action));
    assert.equal(result.before,true);assert.match(result.error,/not at expectedUrl/);assert.deepEqual(calls,['url']);
  }
});
test('native failures stay uncertain and are never replayed',async()=>{
  for(const [action,method] of Object.entries(actions)) {
    const {p,calls}=page({failed:true});const result=await input(p,args(action));
    assert.equal(result.before,undefined);assert.equal(result.error,'reply lost after native input');
    assert.equal(result.receipt,null);assert.equal(calls.filter(c=>Array.isArray(c)&&c[0]===method).length,1);
  }
});
test('a failed URL read refuses every native action before input',async()=>{
  for(const action of Object.keys(actions)) {
    const {p,calls}=page();p.url=async()=>{calls.push('url');throw Error('page closed');};
    const result=await input(p,args(action));assert.equal(result.before,true);assert.equal(result.error,'page closed');assert.deepEqual(calls,['url']);
  }
});

test('native drag failures retain uncertain release without additional input or replay',async()=>{
  let drags=0,ups=0;
  const p={url:async()=>url,dragAndDrop:async()=>{drags++;throw Error('drag interrupted');},mouse:{up:async()=>{ups++;}}};
  const result=await input(p,args('drag_to'));
  assert.equal(drags,1);assert.equal(ups,0);
  assert.equal(result.receipt,null);assert.match(result.error,/drag interrupted/);
});
test('native drag interrupted by dialog has no Page follow-up and no release proof',async()=>{
 const p={url:async()=>url,dragAndDrop:async()=>({dialog:{type:'alert',message:'drag stopped'}})};
 const result=await input(p,args('drag_to'));assert.equal(result.receipt.dialog.message,'drag stopped');
});
