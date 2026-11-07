#!/usr/bin/env node
// Actual DOM execution of the production interaction script, without an OCaml build.
// Usage: node scripts/probe-browser-multi-select.mjs ego EGO_BROWSER OUT SPACE_NAME_OR_ID
// Ego reuses one goal-owned space; the caller finishes it when the whole goal ends.
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdirSync} from 'node:fs';
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {join, resolve} from 'node:path';
import {createHash} from 'node:crypto';

const [mode, executable, output, space] = process.argv.slice(2);
assert(mode === 'ego' && executable && output && space,
  'expected ego, executable, output directory, and the one goal-owned space name or id');
mkdirSync(output,{recursive:true});
const root = resolve(new URL('..',import.meta.url).pathname);
const source = readFileSync(join(root,'lib/browser_interaction.ml'),'utf8');
const interaction = source.split('let script = {js|')[1].split('|js}')[0];
assert(interaction.includes('return interactInPage(arguments[0])'));
const scriptDigest = createHash('sha256').update(interaction).digest('hex');
const fixture = `<!doctype html><meta charset="utf-8"><title>Browser multi-select proof</title>
<h1>Owned browser form fixture</h1><label>Regions <select id="many" multiple size="7">
<option value="a" selected>Alpha</option><option value="b">Beta</option><option value="c">Gamma</option>
<option value="off" disabled>Disabled</option><optgroup label="Disabled group" disabled><option value="group-off">Grouped</option></optgroup>
<option value="dup">Duplicate one</option><option value="dup">Duplicate two</option></select></label>
<label>Single <select id="one"><option value="a">Alpha</option><option value="b">Beta</option><option value="">Empty</option></select></label>
<pre id="events"></pre><script>
window.events=[]; window.behavior='normal';
for(const select of document.querySelectorAll('select')) for(const type of ['input','change']) select.addEventListener(type,()=>{
 window.events.push(type); document.querySelector('#events').textContent=JSON.stringify(window.events);
 if(type==='change' && window.behavior==='reselect') select.options[0].selected=true;
 if(type==='change' && window.behavior==='rewrite') select.options[1].value='rewritten';
});</script>`;
const server = createServer((_req,res)=>{res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'});res.end(fixture);});
server.listen(0,'127.0.0.1'); await once(server,'listening');
const url = `http://127.0.0.1:${server.address().port}/`;
const observations = [];
const expression = args => `(function(){${interaction}\n})(${JSON.stringify(args)})`;
const exercise = async evaluate => {
  const act = async args => {
    await evaluate(`window.events=[]; window.behavior='normal';`);
    const start=performance.now();
    const result=await evaluate(expression({action:'select_option',selector:'#many',expectedUrl:url,...args}));
    const observed=await evaluate(`({values:Array.from(document.querySelector(${JSON.stringify(args.selector ?? '#many')}).selectedOptions,o=>o.value),events:window.events})`);
    observations.push({args,result,observed,elapsed_ms:performance.now()-start}); return {result,observed};
  };
  let answer=await act({values:['c','a']});
  assert.deepEqual(answer.result.selectedValues,['a','c']);
  assert.deepEqual(answer.observed,{values:['a','c'],events:['input','change']});
  for(const [values,message] of [[['b','missing'],'option_not_found'],[['b','off'],'option_disabled'],
    [['b','group-off'],'option_disabled'],[['b','dup'],'option_is_ambiguous'],[['b','b'],'option_values_are_not_distinct']]) {
    answer=await act({values}); assert.deepEqual(answer.result.interactionFailure,{message,effectStarted:false});
    assert.deepEqual(answer.observed,{values:['a','c'],events:[]});
  }
  answer=await act({values:[]}); assert.deepEqual(answer.result.selectedValues,[]);
  assert.deepEqual(answer.observed,{values:[],events:['input','change']});
  answer=await act({selector:'#one',value:'b'}); assert.deepEqual(answer.result.selectedValues,['b']);
  assert.deepEqual(answer.observed,{values:['b'],events:['input','change']});
  answer=await act({selector:'#one',value:''}); assert.deepEqual(answer.result.selectedValues,['']);
  assert.deepEqual(answer.observed,{values:[''],events:['input','change']});
  for(const behavior of ['reselect','rewrite']) {
    await evaluate(`window.events=[];window.behavior=${JSON.stringify(behavior)};`);
    const result=await evaluate(expression({action:'select_option',selector:'#many',expectedUrl:url,values:['b']}));
    assert.deepEqual(result.interactionFailure,{message:'select_changed_during_events',effectStarted:true});
    const observed=await evaluate(`({values:Array.from(document.querySelector('#many').selectedOptions,o=>o.value),events:window.events})`);
    assert.deepEqual(observed.values,behavior==='reselect'?['a','b']:['rewritten']);
    observations.push({behavior,result,observed});
  }
};
try {
  {
    // Send one complete goal-owned invocation, with no shell interpolation.
    const spaceKey=/^\d+$/.test(space)?Number(space):space;
    const code=`const task=await taskSpace(${JSON.stringify(spaceKey)});const page=task.page('p1');console.log('MASC_SPACE '+JSON.stringify({spaceId:task.spaceId,info:await page.info()}));await page.goto(${JSON.stringify(url)});
const observations=[];const url=${JSON.stringify(url)};const interaction=${JSON.stringify(interaction)};
const assert=(await import('node:assert/strict')).default;
const expression=${expression.toString()};const exercise=${exercise.toString()};
await exercise(async code=>page.evaluate(code));console.log('MASC_MULTI_SELECT '+JSON.stringify({spaceId:task.spaceId,observations}));`;
    // The parent must continue serving the fixture while the browser navigates.
    const run=await new Promise((resolve,reject)=>{
      const process=spawn(executable,['nodejs','-e',code],{stdio:['ignore','pipe','pipe']});
      let stdout='',stderr='';
      const timer=setTimeout(()=>process.kill('SIGTERM'),60000);
      process.stdout.on('data',chunk=>{stdout+=chunk;});process.stderr.on('data',chunk=>{stderr+=chunk;});
      process.once('error',error=>{clearTimeout(timer);reject(error);});
      process.once('close',status=>{clearTimeout(timer);resolve({status,stdout,stderr});});
    });
    writeFileSync(join(output,'ego.log'),(run.stdout??'')+(run.stderr??''));
    assert.equal(run.status,0,run.stderr||String(run.error));
    const receipt=((run.stdout??'')+'\n'+(run.stderr??'')).split('\n').find(line=>line.startsWith('MASC_MULTI_SELECT '));
    assert(receipt,'ego did not publish the scenario receipt');const result=JSON.parse(receipt.slice('MASC_MULTI_SELECT '.length));
    observations.push(...result.observations);writeFileSync(join(output,'space.json'),JSON.stringify({spaceId:result.spaceId,finished:false}));
  }
  writeFileSync(join(output,'proof.json'),JSON.stringify({mode,script_sha256:scriptDigest,observations,
    scope:'Actual owned browser DOM executing extracted production JS. Not OCaml parse/wire, host/Add-on integration, installed change, or Keeper model benchmark.'},null,2));
  console.log(JSON.stringify({mode,scenarios:observations.length,script_sha256:scriptDigest}));
} finally {
  await new Promise(done=>server.close(done));
}
