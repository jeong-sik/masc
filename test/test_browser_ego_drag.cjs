const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync(require('node:path').join(__dirname,'../lib/browser_ego_peer.ml'),'utf8')
  .match(/let drag_input = \{js\|([\s\S]*?)\|js\}/)?.[1];
assert.ok(source);
const drag = vm.runInNewContext('('+source+')');
const path = [{x:20,y:30},{x:40,y:15},{x:60,y:30},{x:60,y:30}];
function page(failAt) {
  let held = false, moved = 0;
  const calls=[];
  const mouse={
    async move(x,y) { calls.push(['move',x,y]); moved++;
      if (failAt === 'move' && moved === 2 || failAt === 'position' && moved === 1) throw Error('move failed'); },
    async down() { calls.push(['down']); held=true; if(failAt==='down') throw Error('down failed'); },
    async up() { calls.push(['up']); if(failAt==='up') throw Error('up failed'); held=false; },
  };
  return {mouse,calls,isHeld:()=>held};
}
test('ego native drag follows observed waypoints and releases',async()=>{
  const target=page(); const result=await drag(target,path);
  assert.equal(result.error,null); assert.equal(target.isHeld(),false);
  assert.deepEqual(target.calls,[['move',20,30],['down'],['move',40,15],['move',60,30],['move',60,30],['up']]);
});
test('a native down or movement failure still releases without replay',async()=>{
  for(const failure of ['down','move']) {
    const target=page(failure); const result=await drag(target,path);
    assert.equal(result.error,failure+' failed');
    assert.equal(target.isHeld(),false); assert.equal(target.calls.filter(c=>c[0]==='down').length,1);
    assert.equal(target.calls.at(-1)[0],'up');
  }
});
test('a failed release reports its error and leaves the button held',async()=>{
  const target=page('up'); const result=await drag(target,path);
  assert.equal(result.error,'up failed'); assert.equal(target.isHeld(),true);
});
test('failure before button down leaves no held input',async()=>{
  const target=page('position'); const result=await drag(target,path);
  assert.equal(result.error,'move failed'); assert.equal(target.isHeld(),false);
  assert.equal(target.calls.length,1);
});
