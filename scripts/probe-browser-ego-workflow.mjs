#!/usr/bin/env node
// Production native workflow function, real Ego, and owned local fixture.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {join,resolve} from 'node:path';
import {createHash} from 'node:crypto';
const [executable,output,space]=process.argv.slice(2);
assert(executable&&output&&space,'expected ego executable, output directory and continuing space id');
mkdirSync(output,{recursive:true});
const source=readFileSync(new URL('../lib/browser_ego_workflow.ml',import.meta.url),'utf8').split('let script = {js|')[1].split('|js}')[0];
const server=createServer((req,res)=>{
 const url=new URL(req.url,'http://fixture');res.setHeader('Content-Type','text/html');
 if(url.pathname==='/done')res.end('<!doctype html><title>Native workflow done</title><h1 id="done">Completed native workflow</h1><pre id="state"></pre><script>document.querySelector("pre").textContent=JSON.stringify(Object.fromEntries(new URLSearchParams(location.search)))</script>');
 else res.end('<!doctype html><title>Native workflow start</title><label>Editor<input id="editor"></label><div id="rich" contenteditable="true" role="textbox" aria-label="Rich editor" style="border:1px solid;padding:20px"></div><select id="choice"><option value="a">A</option><option value="b">B</option></select><button id="submit">Continue</button><script>window.pastes=[];document.querySelector("#rich").addEventListener("paste",e=>pastes.push({trusted:e.isTrusted,html:e.clipboardData.getData("text/html")}));document.querySelector("button").onclick=()=>location.href="/done?value="+encodeURIComponent(document.querySelector("input").value)+"&choice="+document.querySelector("select").value</script>');
});
try {
 server.listen(0,'127.0.0.1');await once(server,'listening');
 const origin=`http://localhost:${server.address().port}`,url=origin+'/start';
 const request={tabId:1,expectedUrl:url,steps:[
  {method:'fill',selector:'loc=css:#editor',text:'native workflow'},
  {method:'selectOption',selector:'loc=css:#choice',selectionJson:JSON.stringify({value:'b'})},
  {method:'click',selector:'loc=css:#submit'},
  {method:'waitForURL',url:origin+'/done?value=native%20workflow&choice=b'},
  {method:'waitForSelector',selector:'loc=css:#done',state:'visible'},
 ],snapshotScope:'full_page',maxChars:10000};
 const inputRequest={tabId:1,expectedUrl:url,steps:[
  {method:'reload'},
  {method:'focus',selector:'loc=css:#editor'},
  {method:'keyboard.type',text:'typed'},
  {method:'keyboard.press',key:'ControlOrMeta+A'},
  {method:'keyboard.insertText',text:'한글 😀'},
  {method:'focus',selector:'loc=css:#rich'},
  {method:'keyboard.paste',text:'Name\tStatus',html:'<table><tr><td>Name</td><td>Status</td></tr></table>'},
 ],snapshotScope:'full_page',maxChars:10000};
 const code=`const task=await taskSpace(${JSON.stringify(Number(space))});const page=task.page('p1');
await page.goto(${JSON.stringify(url)});${source}
const assert=(await import('node:assert/strict')).default;
const inputRequest=${JSON.stringify(inputRequest)};
const inputResult=await nativeWorkflow(page,{...inputRequest,cursor:'MASC rich input workflow proof'});
assert.equal(inputResult.failure,null,JSON.stringify(inputResult));
assert.equal(inputResult.completed.length,inputRequest.steps.length);
const inputState=await page.evaluate(()=>({text:document.querySelector('#editor').value,
 rich:document.querySelector('#rich').innerHTML,pastes:window.pastes,
 navigation:performance.getEntriesByType('navigation')[0].type}));
assert.equal(inputState.text,'한글 😀');assert(inputState.rich.includes('<table>'),inputState.rich);
assert.equal(inputState.pastes.length,1);assert.equal(inputState.pastes[0].trusted,true);
assert(inputState.pastes[0].html.includes('<table>'));assert.equal(inputState.navigation,'reload');
await page.screenshot({path:${JSON.stringify(join(resolve(output),'native-rich-input.png'))}});
await page.evaluate(()=>document.querySelector('#editor').addEventListener('input',()=>alert('Keyboard input dialog'),{once:true}));
const dialogRequest={...inputRequest,steps:[
 {method:'focus',selector:'loc=css:#editor'},
 {method:'keyboard.insertText',text:'dialog input'},
 {method:'click',selector:'loc=css:#submit'},
]};
const dialogResult=await nativeWorkflow(page,{...dialogRequest,cursor:'MASC keyboard dialog proof'});
assert(dialogResult.failure,JSON.stringify(dialogResult));
assert.equal(dialogResult.completed.some(step=>step.method==='click'),false);
assert.equal((await page.info()).dialog.message,'Keyboard input dialog');
await page.dismissDialog();assert.equal(await page.url(),inputRequest.expectedUrl);
const request=${JSON.stringify(request)};
const result=await nativeWorkflow(page,{...request,cursor:'MASC native workflow proof'});
assert.equal(result.failure,null,JSON.stringify(result));assert.equal(result.completed.length,request.steps.length);
assert.equal(result.url,${JSON.stringify(origin+'/done?value=native%20workflow&choice=b')});
assert(result.snapshot.includes('Completed native workflow'));assert(result.snapshot.includes('native workflow'));
const state=await page.evaluate(()=>Object.fromEntries(new URLSearchParams(location.search)));
assert.deepEqual(state,{value:'native workflow',choice:'b'});
await page.screenshot({path:${JSON.stringify(join(resolve(output),'native-workflow.png'))}});
const refused=await nativeWorkflow(page,{...request,expectedUrl:request.expectedUrl});
assert.equal(refused.effectStarted,false);assert.equal(refused.completed.length,0);
const stopped=await nativeWorkflow(page,{...request,expectedUrl:result.url,steps:[
 {method:'hover',selector:'loc=css:#done'},
 {method:'waitForSelector',selector:'loc=css:#never',state:'visible',options:{timeout:1}},
 {method:'goto',url:request.expectedUrl}
]});
assert.equal(stopped.completed.length,1);assert.equal(stopped.completedEffect,true);assert.equal(stopped.failure.index,1);
assert.equal(await page.url(),result.url,'failed workflow must not execute its last navigation');
console.log('MASC_WORKFLOW_PROOF '+JSON.stringify({spaceId:task.spaceId,finished:false,inputRequest,inputResult,inputState,dialogRequest,dialogResult,request,result,refused,stopped,state}));`;
 const run=await new Promise((resolve,reject)=>{
  const child=spawn(executable,['nodejs','-e',code],{stdio:['ignore','pipe','pipe']});let log='';
  child.stdout.on('data',chunk=>{log+=chunk;});child.stderr.on('data',chunk=>{log+=chunk;});
  child.once('error',reject);child.once('close',status=>resolve({status,log}));
 });
 writeFileSync(join(output,'sdk-output.txt'),run.log);assert.equal(run.status,0,run.log);
 const line=run.log.split('\n').find(line=>line.startsWith('MASC_WORKFLOW_PROOF '));assert(line,'no workflow proof');
 const proof={...JSON.parse(line.slice('MASC_WORKFLOW_PROOF '.length)),script_sha256:createHash('sha256').update(source).digest('hex'),scope:'Production workflow JS on installed Ego plus owned local fixture; not OCaml host/Keeper dispatch or installed MASC proof.'};
 writeFileSync(join(output,'proof.json'),JSON.stringify(proof,null,2));
 console.log(JSON.stringify({spaceId:proof.spaceId,completed:proof.result.completed.length,failedStep:proof.stopped.failure.index,script_sha256:proof.script_sha256}));
} finally {server.closeAllConnections();await new Promise(done=>server.close(done));}
