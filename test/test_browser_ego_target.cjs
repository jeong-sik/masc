const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync(require('node:path').join(__dirname,'../lib/browser_ego_peer.ml'),'utf8')
  .match(/let target_input_script = \{js\|([\s\S]*?)\|js\}/)?.[1];
assert.ok(source);
const input = vm.runInNewContext('('+source+')');
const url = 'https://example.test/observed';
const actions = {click:'click',fill:'fill',hover:'hover',double_click:'dblclick'};
function page({redirect=false,missing=false,lost=false}={}) {
  const calls=[];let reads=0;
  const p={
    async url(){calls.push('url');return redirect&&++reads===2?'https://example.test/other':url;},
    async waitForSelector(target,options){calls.push(['wait',target,options.state]);if(missing)throw Error('target is missing or ambiguous');},
  };
  for(const method of Object.values(actions))p[method]=async(...args)=>{
    calls.push([method,...args]);if(lost)throw Error('reply lost after native input');return {};
  };
  return {p,calls};
}
const args = action => ({action,target:'@12',expectedUrl:url,text:'literal " value',waitMs:2000,cursor:'MASC · fixture · '+action});
test('each closed snapshot action uses its exact native method once after both URL reads',async()=>{
  for(const [action,method] of Object.entries(actions)) {
    const {p,calls}=page();const result=await input(p,args(action));
    assert.equal(result.error,null);assert.equal(result.urlBefore,url);assert.equal(typeof result.receipt,'object');
    assert.deepEqual(JSON.parse(JSON.stringify(calls)),['url',['wait','@12','attached'],'url',action==='fill'?[method,'@12','literal " value']:action==='click'?[method,'@12',{label:args(action).cursor}]:[method,'@12']]);
  }
});
test('navigation during target discovery refuses every action before native input',async()=>{
  for(const action of Object.keys(actions)) {
    const {p,calls}=page({redirect:true});const result=await input(p,args(action));
    assert.equal(result.before,true);assert.match(result.error,/not at expectedUrl/);
    assert.deepEqual(calls,['url',['wait','@12','attached'],'url']);
  }
});
test('missing or ambiguous target refuses every action before native input',async()=>{
  for(const action of Object.keys(actions)) {
    const {p,calls}=page({missing:true});const result=await input(p,args(action));
    assert.equal(result.before,true);assert.equal(result.error,'target is missing or ambiguous');
    assert.deepEqual(calls,['url',['wait','@12','attached']]);
  }
});
test('an input failure stays uncertain and is never replayed by this boundary',async()=>{
  for(const [action,method] of Object.entries(actions)) {
    const {p,calls}=page({lost:true});const result=await input(p,args(action));
    assert.equal(result.before,undefined);assert.equal(result.error,'reply lost after native input');
    assert.equal(result.receipt,null);assert.equal(calls.filter(c=>Array.isArray(c)&&c[0]===method).length,1);
  }
});

test('a failed URL re-read refuses every native action before input',async()=>{
  for(const action of Object.keys(actions)) {
    const {p,calls}=page();let reads=0;
    p.url=async()=>{calls.push('url');if(++reads===2)throw Error('target page closed');return url;};
    const result=await input(p,args(action));
    assert.equal(result.before,true);assert.equal(result.error,'target page closed');
    assert.deepEqual(calls,['url',['wait','@12','attached'],'url']);
  }
});
