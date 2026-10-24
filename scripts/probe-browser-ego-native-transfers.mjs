import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {writeFileSync,readFileSync,mkdirSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {resolve,join} from 'node:path';
import assert from 'node:assert/strict';
const [executable,output,space]=process.argv.slice(2);assert(executable&&output&&space);mkdirSync(output,{recursive:true});
const source=readFileSync(new URL('../lib/browser_ego_peer.ml',import.meta.url),'utf8');
const upload=source.split('let native_upload_script = {js|')[1].split('|js}')[0];
const target=source.split('let target_input_script = {js|')[1].split('|js}')[0];
const path=join(resolve(output),'note.txt');writeFileSync(path,'native upload probe');
const server=createServer((req,res)=>{res.setHeader('Content-Type','text/html');res.end(`<!doctype html><title>Native transfers</title><label id="label">Attach note<input type="file" id="file"></label><div id="wrapper"><input type="file" id="child"></div><div id="shadow"></div><div id="source" draggable="true">Drag source</div><div id="destination">Drop target</div><pre id="state"></pre><script>const root=document.querySelector('#shadow').attachShadow({mode:'open'});root.innerHTML='<input type="file" id="shadowfile">';window.events=[];document.addEventListener('change',e=>events.push({id:e.target.id,files:[...e.target.files??[]].map(f=>({name:f.name,size:f.size}))}));const dest=document.querySelector('#destination');dest.ondragover=e=>e.preventDefault();dest.ondrop=e=>{e.preventDefault();events.push({drop:true,trusted:e.isTrusted});document.querySelector('pre').textContent='Native drop completed'};</script>`);});
server.listen(0,'127.0.0.1');await once(server,'listening');
try {
 const url=`http://localhost:${server.address().port}/`;
 const code=`const task=await taskSpace(${JSON.stringify(Number(space))}), page=task.page('p1');
await page.goto(${JSON.stringify(url)});console.log(await page.snapshot());${upload};${target};
const assert=(await import('node:assert/strict')).default;
const observations=[];
for(const selector of ['loc=css:#file','loc=css:#label','loc=css:#wrapper','loc=css:#shadowfile']){
 const result=await nativeUpload(page,{selector,paths:[${JSON.stringify(path)}]});assert.equal(result.error,null,JSON.stringify(result));observations.push({selector,result});
}
const snap=await page.snapshot();const ref=snap.match(/textbox \\[ref=(\\d+)\\]/);assert(ref,'file input must have an observed ref');
const refResult=await nativeUpload(page,{selector:'@'+ref[1],paths:[${JSON.stringify(path)}]});assert.equal(refResult.error,null);observations.push({selector:'@'+ref[1],result:refResult});
const drag=await nativeTargetInput(page,{action:'drag_to',target:'loc=css:#source',destination:'loc=css:#destination',expectedUrl:${JSON.stringify(url)},cursor:'MASC native transfer proof'});assert.equal(drag.error,null,JSON.stringify(drag));
await page.waitForSelector('text="Native drop completed"');
const state=await page.evaluate(()=>({events,files:['#file','#child'].map(s=>[...document.querySelector(s).files].map(f=>({name:f.name,size:f.size}))),shadow:[...document.querySelector('#shadow').shadowRoot.querySelector('input').files].map(f=>({name:f.name,size:f.size}))}));
assert(state.events.some(e=>e.drop&&e.trusted));assert.equal(state.files[0][0].name,'note.txt');assert.equal(state.files[1][0].size,19);assert.equal(state.shadow[0].size,19);
const snapshot=await page.snapshot();console.log(snapshot);await page.screenshot({path:${JSON.stringify(join(resolve(output),'native-transfers.png'))}});
console.log('MASC_TRANSFER_PROOF '+JSON.stringify({spaceId:task.spaceId,finished:false,observations,drag,state,snapshot}));`;
 const child=spawn(executable,['nodejs','-e',code],{stdio:['ignore','pipe','pipe']});let out='';child.stdout.on('data',b=>out+=b);child.stderr.on('data',b=>out+=b);const [status]=await once(child,'close');writeFileSync(join(output,'sdk-output.txt'),out);assert.equal(status,0,out);
 const line=out.split('\n').find(x=>x.startsWith('MASC_TRANSFER_PROOF '));assert(line,out);
 const proof={...JSON.parse(line.slice('MASC_TRANSFER_PROOF '.length)),upload_sha256:createHash('sha256').update(upload).digest('hex'),target_sha256:createHash('sha256').update(target).digest('hex'),scope:'Production native upload and target-input JavaScript on installed Ego; not host/Keeper dispatch or deployment proof.'};writeFileSync(join(output,'proof.json'),JSON.stringify(proof,null,2));console.log(JSON.stringify({spaceId:proof.spaceId,uploadObservations:proof.observations.length,trustedDrop:proof.state.events.some(e=>e.drop&&e.trusted),upload_sha256:proof.upload_sha256,target_sha256:proof.target_sha256}));

} finally {server.closeAllConnections();await new Promise(done=>server.close(done));}
