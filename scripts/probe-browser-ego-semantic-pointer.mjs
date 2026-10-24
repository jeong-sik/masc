#!/usr/bin/env node
// Executes the production snapshot-input boundary in one continuing goal space.
// Usage: node scripts/probe-browser-ego-semantic-pointer.mjs EGO OUT SPACE_NAME_OR_ID
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {join,resolve} from 'node:path';
import {createHash} from 'node:crypto';
const [executable,output,space]=process.argv.slice(2);
assert(executable&&output&&space,'expected ego executable, output directory, continuing goal space');
mkdirSync(output,{recursive:true});
const source=readFileSync(new URL('../lib/browser_ego_peer.ml',import.meta.url),'utf8');
const boundary=source.split('let target_input_script = {js|')[1].split('|js}')[0];
const digest=createHash('sha256').update(boundary).digest('hex');
const inner=`<!doctype html><title>Frame controls</title><button id="inner" style="padding:30px">Frame action</button>
<script>for(const type of ['mouseenter','dblclick']) document.querySelector('button').addEventListener(type,event=>parent.postMessage({type,trusted:event.isTrusted},'*'));</script>`;
const frameServer=createServer((_req,res)=>{res.writeHead(200,{'Content-Type':'text/html'});res.end(inner);});
frameServer.listen(0,'127.0.0.1');await once(frameServer,'listening');
const frameOrigin=`http://127.0.0.1:${frameServer.address().port}`;
const outer=`<!doctype html><title>Semantic pointer cross-origin proof</title>
<h1>Owned iframe fixture</h1><button id="outer" style="padding:20px">Frame action</button>
<iframe title="Embedded controls" src="${frameOrigin}/" style="display:block;width:700px;height:300px"></iframe><pre id="events"></pre>
<script>window.state={inner:[],outer:[]};
const render=()=>document.querySelector('#events').textContent=JSON.stringify(state,null,2);
for(const type of ['mouseenter','dblclick']) document.querySelector('button').addEventListener(type,event=>{state.outer.push({type,trusted:event.isTrusted});render();});
addEventListener('message',event=>{if(event.origin===${JSON.stringify(frameOrigin)}&&event.source===document.querySelector('iframe')?.contentWindow){state.inner.push(event.data);render();}});</script>`;
const server=createServer((_req,res)=>{res.writeHead(200,{'Content-Type':'text/html'});res.end(outer);});
try {
 server.listen(0,'127.0.0.1');await once(server,'listening');
 // Different host and port: the frame is cross-origin and cross-site.
 const url=`http://localhost:${server.address().port}/`;
 const spaceKey=/^\d+$/.test(space)?Number(space):space;
 const code=`const assert=(await import('node:assert/strict')).default;
const task=await taskSpace(${JSON.stringify(spaceKey)});const page=task.page('p1');
console.log('MASC_SPACE '+JSON.stringify({spaceId:task.spaceId,info:await page.info()}));
await page.goto(${JSON.stringify(url)});
await page.waitForFunction(()=>document.querySelector('iframe').contentWindow!==null);
${boundary}
const observations=[];
const observe=()=>page.evaluate(()=>structuredClone(window.state));
const snapshot=async()=>{const value=await page.snapshot({scope:'full_page'});const text=typeof value==='string'?value:JSON.stringify(value);console.log('MASC_SNAPSHOT '+text);return text;};
const frameTarget=async()=>{
 const text=await snapshot();
 // Fixture structure: one button under the iframe's root, distinct from the outer lookalike.
 const matches=[...text.matchAll(/^      button \\[ref=(\\d+)\\]$/gm)];
 assert.equal(matches.length,1,'fixture must expose exactly one observed iframe button');return '@'+matches[0][1];
};
const act=async(action,target)=>{
 const result=await nativeTargetInput(page,{action,target,expectedUrl:${JSON.stringify(url)}});
 assert.equal(result.error,null,JSON.stringify(result));
 assert(result.receipt!==null&&typeof result.receipt==='object'&&!Array.isArray(result.receipt),'native receipt must satisfy the actual OCaml peer object contract');
 const kind=action==='hover'?'mouseenter':'dblclick';
 const side=target.startsWith('@')?'inner':'outer';
 await page.waitForFunction(({side,kind})=>state[side].some(e=>e.type===kind),{side,kind});
 const observed=await observe();observations.push({action,target,result,observed});return observed;
};
let state=await act('hover',await frameTarget());
assert.deepEqual(state.outer,[]);assert(state.inner.some(e=>e.type==='mouseenter'&&e.trusted===true));
state=await act('double_click',await frameTarget());
assert.deepEqual(state.outer,[]);assert.equal(state.inner.filter(e=>e.type==='dblclick'&&e.trusted===true).length,1);
await snapshot();state=await act('hover','loc=role:button[name="Frame action"]');
assert(state.outer.some(e=>e.type==='mouseenter'&&e.trusted===true));
await snapshot();state=await act('double_click','text="Frame action"');
assert.equal(state.outer.filter(e=>e.type==='dblclick'&&e.trusted===true).length,1);
assert.equal(state.inner.filter(e=>e.type==='dblclick').length,1,'outer text action does not double-click the iframe again');
const before=await observe();
const refusal=await nativeTargetInput(page,{action:'hover',target:'loc=role:button[name="Frame action"]',expectedUrl:${JSON.stringify(url+'wrong')}});
assert.equal(refusal.before,true);assert.match(refusal.error,/not at expectedUrl/);
assert.deepEqual(await observe(),before);observations.push({action:'wrong_url',result:refusal,observed:before});
await page.screenshot({path:${JSON.stringify(join(resolve(output),'trusted-frame-results.png'))}});
const stale=await frameTarget();await page.evaluate(()=>document.querySelector('iframe').remove());
const missing=await nativeTargetInput(page,{action:'hover',target:stale,expectedUrl:${JSON.stringify(url)}});
assert.equal(missing.before,undefined);assert.equal(typeof missing.error,"string");assert.deepEqual(await observe(),before);
observations.push({action:'removed_frame_ref',target:stale,result:missing,observed:await observe()});
console.log('MASC_PROOF '+JSON.stringify({spaceId:task.spaceId,finished:false,url:${JSON.stringify(url)},frameOrigin:${JSON.stringify(frameOrigin)},observations}));`;
 const run=await new Promise((resolve,reject)=>{
  const child=spawn(executable,['nodejs','-e',code],{stdio:['ignore','pipe','pipe']});let stdout='',stderr='';
  const timer=setTimeout(()=>child.kill('SIGTERM'),60000);
  child.stdout.on('data',chunk=>{stdout+=chunk;});child.stderr.on('data',chunk=>{stderr+=chunk;});
  child.once('error',error=>{clearTimeout(timer);reject(error);});
  child.once('close',status=>{clearTimeout(timer);resolve({status,stdout,stderr});});
 });
 const log=run.stdout+run.stderr;
 writeFileSync(join(output,'ego.log'),log);
 assert.equal(run.status,0,run.stderr);
 const receipt=log.split('\n').find(line=>line.startsWith('MASC_PROOF '));assert(receipt,'ego did not publish a proof');
 const proof={...JSON.parse(receipt.slice('MASC_PROOF '.length)),script_sha256:digest,scope:'Production ego nativeTargetInput boundary; no OCaml typing, host/Add-on integration or autonomous Keeper benchmark.'};
 writeFileSync(join(output,'proof.json'),JSON.stringify(proof,null,2));
 console.log(JSON.stringify({spaceId:proof.spaceId,scenarios:proof.observations.length,script_sha256:digest}));
} finally {
 server.closeAllConnections();frameServer.closeAllConnections();
 await Promise.all([new Promise(done=>server.close(done)),new Promise(done=>frameServer.close(done))]);
}
