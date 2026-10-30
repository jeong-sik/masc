// Production nativeWorkflow on an owned local fixture; not host/Keeper proof.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {once} from 'node:events';
import {readFileSync,writeFileSync} from 'node:fs';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
const source=readFileSync(new URL('../../../lib/browser_ego_workflow.ml',import.meta.url),'utf8');
const script=source.split('let script = {js|')[1].split('|js}')[0];
const directory=fileURLToPath(new URL('./',import.meta.url));
const html='<!doctype html><title>Native Ego waits</title><h1>Native Ego waits</h1><label>Name<input id="name"></label><button id="save">Save</button><p id="result" hidden></p><script>document.querySelector("#save").onclick=()=>{const r=document.querySelector("#result");r.textContent="Saved: "+document.querySelector("#name").value;r.hidden=false;window.submissions=(window.submissions||0)+1;}</script>';
const server=createServer((_req,res)=>{res.writeHead(200,{'Content-Type':'text/html'});res.end(html);});
try {
 server.listen(0,'127.0.0.1');await once(server,'listening');
 const url=`http://127.0.0.1:${server.address().port}/`;
 const steps=[{method:'fill',selector:'#name',text:'Ego owns waits'},
   ...Array.from({length:17},()=>({method:'waitForSelector',selector:'#save',state:'visible',timeoutMs:75000})),
   {method:'click',selector:'#save'},
   {method:'waitForSelector',selector:'#result',state:'visible'}];
 const request={expectedUrl:url,steps,snapshotScope:'viewport',maxChars:12000,cursor:'Verify native SDK waits'};
 const code=`const task=await taskSpace(20);
console.log('MASC_SPACE '+JSON.stringify({id:task.spaceId}));
const page=task.page('p1');await page.goto(${JSON.stringify(url)});
${script}
const result=await nativeWorkflow(page,${JSON.stringify(request)});
const state=await page.evaluate(()=>({text:document.querySelector('#result').textContent,submissions:window.submissions}));
await page.screenshot({path:${JSON.stringify(directory+'native-waits.png')}});
console.log('MASC_PROOF '+JSON.stringify({spaceId:task.spaceId,result,state}));`;
 const child=spawn('ego-browser',['nodejs','-e',code],{stdio:['ignore','pipe','pipe']});let output='';
 child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>output+=b);
 const [status]=await once(child,'exit');
 writeFileSync(directory+'sdk-output.txt',output);
 assert.equal(status,0,output);
 const line=output.split('\n').find(x=>x.startsWith('MASC_PROOF '));assert(line,output);
 const proof={...JSON.parse(line.slice(11)),request,script_sha256:createHash('sha256').update(script).digest('hex'),scope:'Production JS on installed Ego only; not full host or Keeper dispatch'};
 assert.equal(proof.result.failure,null);assert.equal(proof.result.completed.length,20);
 assert.equal(proof.state.submissions,1);assert.equal(proof.state.text,'Saved: Ego owns waits');
 assert(proof.result.snapshot.includes('Saved: Ego owns waits'));
 writeFileSync(directory+'proof.json',JSON.stringify(proof,null,2)+'\n');
 console.log(JSON.stringify({spaceId:proof.spaceId,completed:20,submissions:proof.state.submissions,script_sha256:proof.script_sha256}));
} finally {server.closeAllConnections();await new Promise(done=>server.close(done));}
