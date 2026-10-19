import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { readFile } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'
import { join } from 'node:path'
import { importMidiSource } from '../midi-source.mjs'
import { arrangementFromMidiSource } from '../phrase-arrangement.mjs'
import { selectionLabel, pickerFooter } from '../instruments.mjs'

const flush=()=>new Promise(resolve=>setImmediate(resolve))
const deferred=()=>{let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no});return{promise,resolve,reject}}
const document=()=>{const wire=Buffer.from('4d546864000000060000000101e04d54726b0000000000903c648360803c4d00ff2f00','hex');wire.writeUInt32BE(wire.length-22,18);return importMidiSource(wire)}
async function controller(){
 const observed={workers:[],conversions:[],children:[],opened:[],pickers:[]},process=new EventEmitter()
 process.env={};process.stdin=Object.assign(new EventEmitter(),{isTTY:true,isRaw:false,setRawMode(value){this.isRaw=value},resume(){},pause(){}})
 process.stdout=Object.assign(new EventEmitter(),{isTTY:true,columns:80,rows:24,write(){}})
 class Worker extends EventEmitter{constructor(){super();this.jobs=[];observed.workers.push(this)}postMessage(job){this.jobs.push(job)}async terminate(){this.terminated=true}}
 class InstrumentPicker{constructor(callbacks){Object.assign(this,callbacks);this.view=null;observed.pickers.push(this)}open(){this.soundfont()}close(){}async settled(){}}
 const childDone=deferred(),slot='score-controller-'+randomUUID()
 const open=async(kind,value)=>{observed.opened.push({kind,value});await childDone.promise}
 globalThis[slot]={process,values:{'cell-width':'8','cell-height':'16','project-root':'/projects','session-root':'/takes','state-dir':'/state','midi-output':'42'},Worker,InstrumentPicker,join,tmpdir:()=>'/synthetic',mkdtempSync:()=>'/synthetic/score',chmodSync(){},rmSync(){},
  selectionLabel,pickerFooter,safeText:String,retire:()=>'',place:()=>'',transmit:()=>'',viewport:()=>({scroll:0,availableRows:20,fullRows:20}),snapshotWriter:()=>async()=>{},emitKeypressEvents(){},sourceArrangement:arrangementFromMidiSource,
  scoreDocument(snapshot,{signal}){const pending=deferred();observed.conversions.push({snapshot:structuredClone(snapshot),signal,...pending});signal.addEventListener('abort',()=>pending.reject(signal.reason),{once:true});return pending.promise},
  openSequencer:value=>open('sequence',value),openArrangement:value=>open('arrange',value),openSession:value=>open('record',value),
  spawn(){const child=Object.assign(new EventEmitter(),{stderr:new EventEmitter(),kills:[],kill(signal){this.kills.push(signal)}});observed.children.push(child);return child}}
 const raw=await readFile(new URL('../viewer.mjs',import.meta.url),'utf8')
 const source=raw.slice(raw.indexOf('async function viewScores('))
  .replaceAll("new URL('./worker.mjs', import.meta.url)","new URL('file:///worker')")
  .replace("await import('./sequencer-tui.mjs')",'await Promise.resolve({viewSequencer:openSequencer})')
  .replace("await import('./arrangement-tui.mjs')",'await Promise.resolve({viewArrangement:openArrangement})')
  .replace("await import('./music-session.mjs')",'await Promise.resolve({viewSession:openSession})')
  .replace("await import('./phrase-arrangement.mjs')",'await Promise.resolve({arrangementFromMidiSource:sourceArrangement})')
 const prefix=`const {${Object.keys(globalThis[slot]).join(',')}}=globalThis[${JSON.stringify(slot)}];\n`
 const {viewScores}=await import('data:text/javascript;base64,'+Buffer.from(prefix+source+'\nexport {viewScores}').toString('base64'))
 const done=viewScores(['first score','second score'],0).finally(()=>{delete globalThis[slot]})
 const key=(name,text='')=>process.stdin.emit('keypress',text,{name})
 let replied=0
 const rendered=()=>{const worker=observed.workers[0];while(replied<worker.jobs.length){const job=worker.jobs[replied++];worker.emit('message',{id:job.id,ok:true,result:{title:'Loaded',version:'test',page:0,pageCount:1,tracks:[{index:0,name:'First'},{index:1,name:'Second'}],pages:[{png:Buffer.alloc(0)}]}})}}
 await flush();return{observed,process,done,key,rendered,childDone}
}
test('score admission captures the selected score/track, passes a real source to either child, and restores input',async t=>{
 for(const mode of ['p','a']){
  const view=await controller();t.after(async()=>{view.childDone.resolve();await flush();view.key('q');await view.done})
  view.key('right');view.rendered();view.key('t');view.key('t');view.key(mode);await flush()
  assert.equal(view.observed.conversions.length,1)
  const conversion=view.observed.conversions[0];assert.deepEqual(conversion.snapshot,{source:'second score',tracks:[1]})
  view.key('left');view.key('a');assert.equal(view.observed.conversions.length,1)
  const source=document();conversion.resolve(source);await flush()
  const opened=view.observed.opened[0];assert.ok(opened,mode)
  assert.equal(opened.value.midiOutput,'42');assert.equal(opened.value.stateDirectory,'/state')
  assert.deepEqual(mode==='p'?opened.value.initialDocument:opened.value.initialDocument.assets[0].source,source)
  assert.equal(view.process.stdin.listenerCount('keypress'),0)
  view.childDone.resolve();await flush();assert.equal(view.process.stdin.listenerCount('keypress'),1)
  view.key('q');await view.done
  assert.equal(view.process.stdin.isRaw,false);assert.ok(view.observed.workers.every(w=>w.terminated))
 }
})
test('pending conversion remains cancellable and never opens a late or blank child on close or source refusal',async()=>{
 for(const ending of ['close','reject']){
  const view=await controller();view.key('p');await flush();const conversion=view.observed.conversions[0]
  if(ending==='close')view.key('q')
  else{conversion.reject(new Error('Official source diagnostic'));await flush();assert.equal(view.process.stdin.listenerCount('keypress'),1);view.key('q')}
  await view.done;assert.equal(conversion.signal.aborted,true);assert.equal(view.observed.opened.length,0)
  assert.equal(view.process.stdin.isRaw,false)
 }
})
test('a paused score player is continued/stopped and actually closes before the source editor receives input',async()=>{
 const view=await controller();view.key('space')
 const audio=view.observed.workers[1],job=audio.jobs.at(-1)
 audio.emit('message',{id:job.id,ok:true,result:{path:'/owned/score.wav',durationMs:2000}})
 const player=view.observed.children[0];player.emit('spawn');view.key('space');view.key('p');await flush()
 assert.deepEqual(player.kills,['SIGSTOP','SIGCONT','SIGTERM'])
 view.observed.conversions[0].resolve(document());await flush();assert.equal(view.observed.opened.length,0)
 player.emit('exit',0,null);await flush();assert.equal(view.observed.opened.length,0)
 player.emit('close',0,null);await flush();assert.equal(view.observed.opened.length,1)
 view.childDone.resolve();await flush();view.key('q');await view.done
 assert.equal(view.process.stdin.isRaw,false)
})
