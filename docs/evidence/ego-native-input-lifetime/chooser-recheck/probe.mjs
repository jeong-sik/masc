import {createServer} from 'node:http';
import {once} from 'node:events';
import {readFileSync,writeFileSync} from 'node:fs';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
const directory=fileURLToPath(new URL('./',import.meta.url));
const peer=readFileSync(new URL('../../../../lib/browser_ego_peer.ml',import.meta.url),'utf8');
const body=peer.slice(peer.indexOf('let choose_files ')).match(/      "      let failure = null[\s\S]*?(?=      "      const dialog)/)[0].split('\n').filter(x=>x.trim()).map(x=>JSON.parse(x.trim().replace(/;$/,''))).join('\n');
writeFileSync(directory+'note.txt','Owned native chooser recheck\n');
const html='<!doctype html><title>SDK chooser lifecycle</title><label>Attach fixture<input id="attach" type="file"></label><p id="result">ready</p><script>document.querySelector("#attach").onchange=e=>document.querySelector("#result").textContent=e.target.files[0]?.name||"empty";</script>';
const server=createServer((req,res)=>{res.writeHead(200,{'content-type':'text/html'});res.end(html);});
try{
 server.listen(0,'127.0.0.1');await once(server,'listening');
 const script=`const task=await taskSpace(25);const native=task.page('p1');
await native.goto('http://127.0.0.1:${server.address().port}/');console.log('INITIAL',await native.snapshot());
const assignments=[];let induceFailure=true;
const page={click:(...args)=>native.click(...args),waitForFileChooser:async()=>{
 const chooser=await native.waitForFileChooser();return {isMultiple:()=>chooser.isMultiple(),setFiles:async(paths)=>{
 assignments.push(paths);if(induceFailure&&paths.length){await native.evaluate(()=>document.querySelector('#attach').type='text');}
 return await chooser.setFiles(paths);
 }};
}};
const choose=async(args)=>{const reason=String;${body};return {failure,set};};
const args={opener:'loc=role:textbox[name="Attach fixture"]',cursor:'Verify native chooser lifecycle',paths:[${JSON.stringify(directory+'note.txt')}]};
const first=await choose(args);console.log('FIRST',JSON.stringify(first));
await native.evaluate(()=>document.querySelector('#attach').type='file');induceFailure=false;
console.log('RECOVERED',await native.snapshot());
const second=await choose(args);console.log('SECOND',JSON.stringify(second));
console.log('ASSIGNMENTS',JSON.stringify(assignments));console.log('FINAL',await native.snapshot());`;
 const child=spawn('ego-browser',['nodejs','-e',script],{stdio:['ignore','pipe','pipe']});let output='';
 child.stdout.on('data',x=>output+=x);child.stderr.on('data',x=>output+=x);
 const [status]=await once(child,'exit');writeFileSync(directory+'sdk-output.txt',output);
 assert.equal(status,0,output);assert.match(output,/Node is not a file input element/);assert.match(output,/SECOND {"failure":null/);
 const assignments=JSON.parse(output.split('\n').find(x=>x.startsWith('ASSIGNMENTS ')).slice(12));assert.equal(assignments.length,2);assert(assignments.every(x=>x.length===1));
 console.log(output);
}finally{server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
