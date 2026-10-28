#!/usr/bin/env node
// Production workflow function on real Ego with owned local HTTP fixtures.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {resolve,join} from 'node:path';
import {createHash} from 'node:crypto';
const [executable,output,space]=process.argv.slice(2);
assert(executable&&output&&space,'expected Ego executable, output directory and continuing space id');
mkdirSync(output,{recursive:true});
const source=readFileSync(new URL('../lib/browser_ego_workflow.ml',import.meta.url),'utf8').split('let script = {js|')[1].split('|js}')[0];
const received=[];let corsReads=0;
const server=createServer(async(req,res)=>{
 if(req.url==='/api') {
  let body='';for await(const chunk of req)body+=chunk;
  received.push({method:req.method,body,header:req.headers['x-fixture']});
  res.writeHead(201,{'Content-Type':'application/json'});
  res.end(JSON.stringify({accepted:true,body}));
 }else res.end('<!doctype html><title>Ego Page SDK fixture</title><h1>Page SDK workflow</h1><p id="state">Waiting for application state</p>');
});
const cors=createServer((req,res)=>{corsReads++;res.end('CORS must protect this response');});
try {
 for(const item of [server,cors]){item.listen(0,'127.0.0.1');await once(item,'listening');}
 const origin=`http://localhost:${server.address().port}`,url=origin+'/start';
 const request={tabId:1,expectedUrl:url,steps:[
  {method:'evaluate',source:'value => { document.querySelector("#state").textContent=value.text;setTimeout(()=>window.fixtureReady=true,25);return {text:value.text,host:typeof process,dialog:"application data"};}',argumentJson:JSON.stringify({text:'한글 😀 " ) ; globalThis.escape = true;//'})},
  {method:'waitForFunction',source:'value => window.fixtureReady === value',argumentJson:'true',options:{polling:1,timeout:3000}},
  {method:'fetch',url:'/api',options:{method:'POST',headers:{'Content-Type':'text/plain','X-Fixture':'native-page-fetch'},body:'한글 😀',credentials:'same-origin',cache:'no-store',mode:'cors',redirect:'error',keepalive:false,referrerPolicy:'no-referrer',timeout:3000}},
  {method:'evaluate',source:'({text:document.querySelector("#state").textContent,escaped:typeof escape,ready:window.fixtureReady})'},
  {method:'evaluate',source:'value => ({own:Object.hasOwn(value,"__proto__"),plain:Object.getPrototypeOf(value)===Object.prototype,data:value.__proto__.polluted})',argumentJson:'{"__proto__":{"polluted":true}}'},
 ],snapshotScope:'full_page',maxChars:10000};
 const code=`const task=await taskSpace(${JSON.stringify(Number(space))});const page=task.page('p1');
await page.goto(${JSON.stringify(url)});
${source}
const assert=(await import('node:assert/strict')).default;
const request=${JSON.stringify(request)};
const result=await nativeWorkflow(page,request);
assert.equal(result.failure,null,JSON.stringify(result));assert.equal(result.completed.length,5);
assert.equal(result.completed[0].receipt.host,'undefined');
assert.equal(result.completed[0].receipt.dialog,'application data');
assert.equal(result.completed[2].receipt.status,201,JSON.stringify(result.completed[2]));
assert.equal(result.completed[3].receipt.ready,true);
assert.equal(result.completed[3].receipt.text,JSON.parse(request.steps[0].argumentJson).text);
assert.equal(result.completed[3].receipt.escaped,'function','JSON content did not replace browser escape');
assert.deepEqual(result.completed[4].receipt,{own:true,plain:true,data:true});
assert(result.snapshot.includes('한글 😀'));
await page.screenshot({path:${JSON.stringify(join(resolve(output),'page-sdk.png'))}});
const blockedRequest={...request,steps:[
 {method:'fetch',url:${JSON.stringify(`http://127.0.0.1:${cors.address().port}/blocked`)},options:{timeout:3000}},
 {method:'evaluate',source:'window.shouldNotRun = true'},
]};
const blocked=await nativeWorkflow(page,blockedRequest);
assert(blocked.failure,JSON.stringify(blocked));assert.equal(blocked.failure.method,'fetch');
assert.equal(blocked.effectStarted,true);assert.equal(blocked.completed.length,0);
assert.equal(await page.evaluate('typeof window.shouldNotRun'),'undefined');
const timeoutRequest={...request,steps:[
 {method:'waitForFunction',source:'(() => {window.predicateVisits=(window.predicateVisits||0)+1;return false})()',options:{timeout:1,polling:1}},
 {method:'evaluate',source:'window.shouldNotRun = true'},
]};
const timedOut=await nativeWorkflow(page,timeoutRequest);
assert(timedOut.failure);assert.equal(timedOut.effectStarted,true);assert.equal(timedOut.completed.length,0);
assert.equal(await page.evaluate('typeof window.shouldNotRun'),'undefined');
console.log('MASC_PAGE_CODE_PROOF '+JSON.stringify({spaceId:task.spaceId,page:page.label,finished:false,request,result,blockedRequest,blocked,timeoutRequest,timedOut}));`;
 const run=await new Promise((resolve,reject)=>{
  const child=spawn(executable,['nodejs','-e',code],{stdio:['ignore','pipe','pipe']});let log='';
  child.stdout.on('data',chunk=>{log+=chunk;});child.stderr.on('data',chunk=>{log+=chunk;});
  child.once('error',reject);child.once('close',status=>resolve({status,log}));
 });
 writeFileSync(join(output,'sdk-output.txt'),run.log);assert.equal(run.status,0,run.log);
 const line=run.log.split('\n').find(line=>line.startsWith('MASC_PAGE_CODE_PROOF '));assert(line,'missing proof');
 assert.equal(received.length,1,'a browser POST must never replay');
 assert.deepEqual(received[0],{method:'POST',body:'한글 😀',header:'native-page-fetch'});
 assert.equal(corsReads,1,'a failed CORS read must never replay');
 const proof={...JSON.parse(line.slice('MASC_PAGE_CODE_PROOF '.length)),received,corsReads,
  script_sha256:createHash('sha256').update(source).digest('hex'),
  scope:'Production workflow JS on installed Ego and owned local fixtures. Not full OCaml host/installed MASC/Keeper/UI proof.'};
 writeFileSync(join(output,'proof.json'),JSON.stringify(proof,null,2));
 console.log(JSON.stringify({spaceId:proof.spaceId,completed:proof.result.completed.length,posts:received.length,corsReads,script_sha256:proof.script_sha256}));
}finally {
 for(const item of [server,cors]){item.closeAllConnections();await new Promise(done=>item.close(done));}
}
