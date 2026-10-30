#!/usr/bin/env node
// Actual production workflow JS with an owned real-Ego local fixture.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {createServer} from 'node:http';
import {spawn,execFileSync} from 'node:child_process';
import {once} from 'node:events';
import {join,resolve} from 'node:path';
import {createHash} from 'node:crypto';
const [executable,output,space]=process.argv.slice(2);
assert(executable&&output&&/^\d+$/.test(space),'expected executable, output directory, continuing Space id');
mkdirSync(output,{recursive:true});
const source=readFileSync(new URL('../lib/browser_ego_workflow.ml',import.meta.url),'utf8').split('let script = {js|')[1].split('|js}')[0];
const posts=[];
const html=`<!doctype html><meta charset="utf-8"><title>MASC · Ego native options verification</title>
<style>body{font:20px system-ui;background:#10202e;color:#e6eff7;margin:28px}h1{font-size:28px}input,select,button{font:20px system-ui;margin:8px;padding:10px}#targets{display:flex;gap:24px;margin:16px}#source,#target{padding:22px;background:#294b62;border:2px solid #85cee8;min-width:180px}#scroll{height:140px;overflow:auto;border:2px solid #85cee8;width:650px;padding:8px}#result{color:#91f5ba;white-space:pre-wrap}#status{font-weight:bold;color:#ffd778}</style>
<h1>MASC · Ego native options verification</h1><p id="status">Native input ready · this is an owned local fixture</p>
<label>Editor<input id="editor" value="seed"></label><br>
<label>Single<select id="single"><option value="a">Alpha</option><option value="b" disabled>Beta disabled</option><option value="c">Gamma</option></select></label>
<label>Multiple<select id="multi" multiple><option value="a">Alpha</option><option value="b" disabled>Beta disabled</option><option value="c">Gamma</option></select></label>
<button id="action">Pointer target</button><div id="targets"><div id="source" draggable="true">Drag source</div><div id="target">Drop target</div></div>
<div id="scroll"><div style="height:700px">Scroll this panel with native wheel input.<br>Observe the native cursor labels while the agent acts.<p style="margin-top:550px">Panel bottom</p></div></div><pre id="result"></pre>
<script>window.events=[];window.ready=true;for(const type of ['pointerdown','pointerup','click','dblclick','contextmenu','input','change','dragstart','drop'])document.addEventListener(type,e=>{events.push({type,target:e.target.id,trusted:e.isTrusted,button:e.button});if(type==='contextmenu')e.preventDefault();});document.querySelector('#target').ondragover=e=>e.preventDefault();document.querySelector('#target').ondrop=e=>e.preventDefault();</script>`;
const server=createServer(async(req,res)=>{
 const url=new URL(req.url,'http://fixture');
 if(url.pathname==='/api'){
  let body='';for await(const chunk of req)body+=chunk;
  posts.push({method:req.method,body,header:req.headers['x-fixture']});
  res.setHeader('Content-Type','application/json');res.end(JSON.stringify(posts.at(-1)));return;
 }
 res.setHeader('Content-Type','text/html; charset=utf-8');res.end(html);
});
try {
 server.listen(0,'127.0.0.1');await once(server,'listening');
 const url=`http://localhost:${server.address().port}/options`;
 const code=`const assert=(await import('node:assert/strict')).default;
const task=await taskSpace(${JSON.stringify(Number(space))}),page=task.page('p1');
await page.goto(${JSON.stringify(url)});console.log(await page.snapshot());
${source}
const expectedUrl=${JSON.stringify(url)};
const request={tabId:1,expectedUrl,steps:[
 {method:'goto',url:expectedUrl,options:{waitUntil:'commit',referer:expectedUrl+'?from=fixture'}},
 {method:'waitForLoadState',options:{timeout:5000}},
 {method:'reload',options:{waitUntil:'domcontentloaded',timeout:5000}},
 {method:'waitForLoadState',state:'networkidle',options:{idleMs:50,timeout:5000}},
 {method:'focus',selector:'loc=css:#editor',options:{timeout:3000}},
 {method:'fill',selector:'loc=css:#editor',text:' appended',options:{clearFirst:false,timeout:3000}},
 {method:'keyboard.type',text:' visible native typing',options:{delay:50}},
 {method:'press',selector:'loc=css:#editor',key:'End',options:{delay:50,timeout:3000}},
 {method:'keyboard.press',key:'End',options:{delay:50}},
 {method:'selectOption',selector:'loc=css:#single',selectionJson:'{"label":"Beta disabled"}',options:{timeout:3000}},
 {method:'evaluate',source:'document.querySelector("#single").value'},
 {method:'selectOption',selector:'loc=css:#single',selectionJson:'{"index":2}'},
 {method:'selectOption',selector:'loc=css:#single',selectionJson:'"Alpha"'},
 {method:'selectOption',selector:'loc=css:#multi',selectionJson:'["a",{"index":2},{"value":"b"}]'},
 {method:'evaluate',source:'Array.from(document.querySelector("#multi").selectedOptions,o=>o.value)'},
 {method:'selectOption',selector:'loc=css:#multi',selectionJson:'null'},
 {method:'selectOption',selector:'loc=css:#multi',selectionJson:'[]'},
 {method:'hover',selector:'loc=css:#action',options:{position:{x:15,y:15},force:false,timeout:3000,label:'Point at native target'}},
 {method:'click',selector:'loc=css:#action',options:{button:'right',delay:150,position:{x:15,y:15},force:false,timeout:3000,label:'Open fixture context action'}},
 {method:'dblclick',selector:'loc=css:#action',options:{button:'left',delay:100,position:{x:15,y:15},timeout:3000,label:'Double click fixture target'}},
 {method:'dragAndDrop',selector:'loc=css:#source',destination:'loc=css:#target',options:{button:'left',sourcePosition:{x:15,y:15},targetPosition:{x:15,y:15},force:false,timeout:3000,label:'Drag into fixture target'}},
 {method:'fetch',url:'/api',options:{method:'POST',body:'native relative fetch',headers:{'X-Fixture':'native-options'},timeout:3000}},
],snapshotScope:'full_page',maxChars:14000};
const result=await nativeWorkflow(page,{...request,cursor:'MASC options proof'});
assert.equal(result.failure,null,JSON.stringify(result));assert.equal(result.inputReleased,true);
assert.equal(result.completed[10].receipt,'b');
assert.deepEqual(result.completed[14].receipt,['a','b','c']);
const observed=await page.evaluate(()=>({editor:document.querySelector('#editor').value,single:document.querySelector('#single').value,multiple:Array.from(document.querySelector('#multi').selectedOptions,o=>o.value),events,geometry:Object.fromEntries(['action','scroll'].map(id=>{const r=document.getElementById(id).getBoundingClientRect();return [id,{x:r.x+r.width/2,y:r.y+Math.min(r.height/2,40)}]}))}));
assert.equal(observed.editor,' appended visible native typingseed');assert.equal(observed.single,'a');assert.deepEqual(observed.multiple,[]);
assert(observed.events.some(e=>e.type==='contextmenu'&&e.target==='action'&&e.trusted));
assert(observed.events.some(e=>e.type==='dblclick'&&e.target==='action'&&e.trusted));
const mouseRequest={tabId:1,expectedUrl,steps:[
 {method:'mouse.move',...observed.geometry.action,options:{steps:5,label:'Move to observed target'}},
 {method:'mouse.click',...observed.geometry.action,options:{button:'left',clickCount:2,delay:100,label:'Click observed target twice'}},
 {method:'mouse.move',...observed.geometry.scroll,options:{steps:5,label:'Move over scroll panel'}},
 {method:'mouse.wheel',x:0,y:180,options:{label:'Scroll observed fixture panel'}},
 {method:'waitForFunction',source:'document.querySelector("#scroll").scrollTop > 0',options:{timeout:3000,polling:10}},
],snapshotScope:'full_page',maxChars:14000};
const mouseResult=await nativeWorkflow(page,{...mouseRequest,cursor:'MASC options proof'});
assert.equal(mouseResult.failure,null,JSON.stringify(mouseResult));assert.equal(mouseResult.inputReleased,true);
const final=await page.evaluate(()=>({editor:document.querySelector('#editor').value,scrollTop:document.querySelector('#scroll').scrollTop,events}));
assert(final.scrollTop>0);assert(final.events.some(e=>e.type==='input'&&e.trusted));
await page.evaluate(value=>{document.querySelector('#status').textContent='Native options verified · Space '+value;document.querySelector('#result').textContent='Trusted native input, selection, pointer, drag and relative fetch completed. '+document.querySelector('#editor').value;},task.spaceId);
await page.screenshot({path:${JSON.stringify(join(resolve(output),'native-options.png'))}});
console.log('MASC_OPTIONS_PROOF '+JSON.stringify({spaceId:task.spaceId,finished:false,request,result,mouseRequest,mouseResult,observed,final}));`;
 const generated=join(resolve(output),'sdk-script.mjs');writeFileSync(generated,code);
 execFileSync(process.execPath,['--check',generated]);
 const run=await new Promise((resolve,reject)=>{
  const child=spawn(executable,['nodejs','-e',code],{stdio:['ignore','pipe','pipe']});let log='';
  child.stdout.on('data',chunk=>{log+=chunk;});child.stderr.on('data',chunk=>{log+=chunk;});
  child.once('error',reject);child.once('close',status=>resolve({status,log}));
 });
 writeFileSync(join(output,'sdk-output.txt'),run.log);assert.equal(run.status,0,run.log);
 assert.equal(posts.length,1);assert.deepEqual(posts[0],{method:'POST',body:'native relative fetch',header:'native-options'});
 const line=run.log.split('\n').find(line=>line.startsWith('MASC_OPTIONS_PROOF '));assert(line,'no options proof');
 const proof={...JSON.parse(line.slice('MASC_OPTIONS_PROOF '.length)),posts,script_sha256:createHash('sha256').update(source).digest('hex'),scope:'Production workflow JS on installed Ego with owned fixture; not full OCaml host, installed Keeper or operator-observed motion proof.'};
 writeFileSync(join(output,'proof.json'),JSON.stringify(proof,null,2));
 console.log(JSON.stringify({spaceId:proof.spaceId,completed:proof.result.completed.length,mouseCompleted:proof.mouseResult.completed.length,posts:posts.length,script_sha256:proof.script_sha256}));
} finally {server.closeAllConnections();await new Promise(done=>server.close(done));}
