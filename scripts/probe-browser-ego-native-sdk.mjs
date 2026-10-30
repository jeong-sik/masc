#!/usr/bin/env node
// Runs the production native-input boundary against owned local fixtures.
// One continuing goal task space; leave it open until the full user goal ends.
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
const inner='<!doctype html><label>Frame input<input id="frame-input"></label><button id="frame-button">Frame action</button><script>window.clicks=[];document.querySelector("button").onclick=e=>{clicks.push(e.isTrusted);parent.postMessage({fixtureFrameClick:e.isTrusted},"*")}</script>';
const frameServer=createServer((_req,res)=>{res.writeHead(200,{'Content-Type':'text/html'});res.end(inner);});
frameServer.listen(0,'127.0.0.1');await once(frameServer,'listening');
const outer=`<!doctype html><title>Ego native SDK proof</title>
<h1>Owned SDK fixture</h1><label>Editor<input id="editor"></label>
<select id="single"><option value="a">A</option><option value="b">B</option><option value="disabled" disabled>Disabled</option></select>
<select id="multi" multiple><option value="a">A</option><option value="b">B</option></select>
<button id="dialog" onclick="alert('Native dialog')">Open dialog</button>
<iframe title="Frame" src="http://127.0.0.1:${frameServer.address().port}/" style="display:block;width:600px;height:220px"></iframe>
<div id="shadow"></div><div style="height:1900px"></div><button id="offscreen">Offscreen action</button><pre id="state"></pre>
<script>window.events=[];window.frameClicks=[];addEventListener('message',e=>{if(e.source===document.querySelector('iframe').contentWindow&&typeof e.data?.fixtureFrameClick==='boolean')frameClicks.push(e.data.fixtureFrameClick)});for(const type of ['click','dblclick','mouseenter','input','change'])document.addEventListener(type,e=>events.push({id:e.target.id,type,trusted:e.isTrusted}),true);
const root=document.querySelector('#shadow').attachShadow({mode:'open'});root.innerHTML='<button id="shadow-button">Shadow action</button>';root.querySelector('button').onclick=e=>events.push({id:'shadow-button',type:'click',trusted:e.isTrusted});</script>`;
const server=createServer((_req,res)=>{res.writeHead(200,{'Content-Type':'text/html'});res.end(outer);});
try {
 server.listen(0,'127.0.0.1');await once(server,'listening');
 const url=`http://localhost:${server.address().port}/`;
 const spaceKey=/^\d+$/.test(space)?Number(space):space;
 const code=`const assert=(await import('node:assert/strict')).default;
const task=await taskSpace(${JSON.stringify(spaceKey)});const page=task.page('p1');
console.log('MASC_SPACE '+JSON.stringify({spaceId:task.spaceId}));
await page.goto(${JSON.stringify(url)});${boundary}
const observed=[];
const act=async(action,target,extra={})=>{
 const result=await nativeTargetInput(page,{action,target,expectedUrl:${JSON.stringify(url)},cursor:'MASC native SDK proof',...extra});
 assert.equal(result.error,null,JSON.stringify(result));assert(result.receipt&&typeof result.receipt==='object');observed.push({action,target,result});return result;
};
await act('fill','loc=css:#editor',{text:'native editor'});
assert.equal(await page.evaluate(()=>document.querySelector('#editor').value),'native editor');
await act('select_option','loc=css:#single',{selection:{value:'b'}});
assert.equal(await page.evaluate(()=>document.querySelector('#single').value),'b');
await act('select_option','loc=css:#single',{selection:{value:'disabled'}});
assert.equal(await page.evaluate(()=>document.querySelector('#single').value),'disabled');
await act('select_option','loc=css:#multi',{selection:[{value:'a'},{value:'b'}]});
assert.deepEqual(await page.evaluate(()=>[...document.querySelector('#multi').selectedOptions].map(o=>o.value)),['a','b']);
await act('select_option','loc=css:#multi',{selection:[]});
assert.deepEqual(await page.evaluate(()=>[...document.querySelector('#multi').selectedOptions].map(o=>o.value)),[]);
await act('click','loc=css:#offscreen');
assert(await page.evaluate(()=>scrollY>0));assert(await page.evaluate(()=>events.some(e=>e.id==='offscreen'&&e.type==='click'&&e.trusted)));
await act('click','loc=css:#shadow-button');
assert(await page.evaluate(()=>events.some(e=>e.id==='shadow-button'&&e.trusted)));
await act('hover','loc=css:#editor');
await act('double_click','loc=css:#editor');
assert(await page.evaluate(()=>events.some(e=>e.id==='editor'&&e.type==='dblclick'&&e.trusted)));
const snap=await page.snapshot({scope:'full_page'});console.log('MASC_SNAPSHOT '+snap);
// Native semantic locator searches the cross-origin frame when the top document has no match.
await act('fill','loc=css:#frame-input',{text:'native frame'});
await act('click','loc=role:button[name="Frame action"]');
await page.waitForFunction(()=>frameClicks.length===1);assert.deepEqual(await page.evaluate(()=>frameClicks),[true]);
const frameSnapshot=await page.snapshot({scope:'full_page'});
const ref=frameSnapshot.match(/textbox \\[ref=(\\d+)\\]\\n\\s+text \"native frame\"/);
assert(ref,'snapshot must expose the observed iframe textbox ref');await act('fill','@'+ref[1],{text:'native frame ref'});
await act('click','loc=css:#dialog');
const pending=await page.info();assert.equal(pending.dialog.message,'Native dialog');
await page.dismissDialog();await act('fill','loc=css:#editor',{text:'resumed after dialog'});
const bad=await nativeTargetInput(page,{action:'click',target:'loc=css:#offscreen',expectedUrl:${JSON.stringify(url+'wrong')}});
assert.equal(bad.before,true);observed.push({action:'wrong_url',result:bad});
await page.waitForFunction(()=>document.querySelector('#editor').value==='resumed after dialog');
console.log('MASC_FINAL_SNAPSHOT '+await page.snapshot());
const events=await page.evaluate(()=>events);await page.screenshot({path:${JSON.stringify(join(resolve(output),'native-sdk-results.png'))}});
console.log('MASC_PROOF '+JSON.stringify({spaceId:task.spaceId,finished:false,url:${JSON.stringify(url)},observations:observed,events}));`;
 const run=await new Promise((resolve,reject)=>{
  const child=spawn(executable,['nodejs','-e',code],{stdio:['ignore','pipe','pipe']});let stdout='',stderr='';
  child.stdout.on('data',chunk=>{stdout+=chunk;});child.stderr.on('data',chunk=>{stderr+=chunk;});
  child.once('error',reject);child.once('close',status=>resolve({status,stdout,stderr}));
 });
 writeFileSync(join(output,'ego.log'),run.stdout+run.stderr);
 assert.equal(run.status,0,run.stdout+run.stderr);
 const line=(run.stdout+run.stderr).split('\n').find(line=>line.startsWith('MASC_PROOF '));assert(line,'no final proof');
 const proof={...JSON.parse(line.slice('MASC_PROOF '.length)),script_sha256:digest,scope:'Production JS native-input boundary on installed Ego; not OCaml typing, Add-on/host dispatch, autonomous Keeper execution, or deployment proof.'};
 writeFileSync(join(output,'proof.json'),JSON.stringify(proof,null,2));
 console.log(JSON.stringify({spaceId:proof.spaceId,scenarios:proof.observations.length,script_sha256:digest}));
} finally {
 server.closeAllConnections();frameServer.closeAllConnections();
 await Promise.all([new Promise(done=>server.close(done)),new Promise(done=>frameServer.close(done))]);
}
