import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { PassThrough } from 'node:stream'
import { access, readFile } from 'node:fs/promises'
import { dirname } from 'node:path'
import { openLiveMidi, backingMidiClaims, liveMidiPlan } from '../live-midi.mjs'
const routes = [{source:'10',destination:'42',scope:{kind:'channels',channels:[{group:3,channel:5}]}}]
const state = (kind='monitoring',extra={}) => ({kind,deliveryProtocol:2,bindings:[{port:0,source:'10',device:{kind:'midi',protocol:2,id:'42',name:'Instrument'},scope:routes[0].scope}],forwardedMessages:'0',filteredMessages:'0',pendingWords:0,...extra})
function child() { return Object.assign(new EventEmitter(),{stdin:new PassThrough(),stdout:new PassThrough(),stderr:new PassThrough(),kills:[],kill(signal){this.kills.push(signal)}}) }
const flush=()=>new Promise(resolve=>setImmediate(resolve))
test('live MIDI validates selected acknowledgements and retains process and private plan through close',async()=>{
 const p=child(),commands=[];p.stdin.on('data',bytes=>commands.push(bytes.toString()))
 let planPath
 const handle=await openLiveMidi({routes,reserved:[{destination:'42',scope:{kind:'channels',channels:[{group:0,channel:1}]}}],spawnProcess(executable,args){planPath=args[1];return p}})
 assert.deepEqual(JSON.parse(await readFile(planPath)),liveMidiPlan(routes,[{destination:'42',scope:{kind:'channels',channels:[{group:0,channel:1}]}}]))
 p.stdout.write(JSON.stringify(state())+'\n');await handle.ready
 let closed=false;handle.completion.then(()=>{closed=true})
 handle.stop();handle.stop();assert.deepEqual(commands,['{"kind":"stop"}\n'])
 p.stdout.write(JSON.stringify(state('stopped',{success:true}))+'\n');await flush();assert.equal(closed,false);await access(planPath)
 p.emit('close',0,null);await handle.completion;await assert.rejects(access(dirname(planPath)),{code:'ENOENT'})
})
test('wrong source/scope/device, malformed state, missing final or failed child never become successful admission',async()=>{
 for(const variant of ['source','scope','device','counter','final','code','callback']) {
  const p=child(),handle=await openLiveMidi({routes,reserved:[],spawnProcess:()=>p,onEvent(){if(variant==='callback')throw Error('observer failure')}})
  const event=state();if(variant==='source')event.bindings[0].source='11'
  if(variant==='scope')event.bindings[0].scope={kind:'endpoint'}
  if(variant==='device')event.bindings[0].device.id='43'
  if(variant==='counter')event.forwardedMessages=0
  const done=assert.rejects(handle.completion)
  p.stdout.write(JSON.stringify(event)+'\n');await flush()
  if(variant==='code')p.stdout.write(JSON.stringify(state('stopped',{success:true}))+'\n')
  p.emit('close',variant==='code'?1:0,null);await done
  if(!['final','code'].includes(variant))assert.ok(p.kills.includes('SIGTERM'))
 }
})
test('abort during live ownership waits for close; aborted preparation opens no child',async()=>{
 const controller=new AbortController();controller.abort();let spawned=0
 await assert.rejects(openLiveMidi({routes,reserved:[],signal:controller.signal,spawnProcess(){spawned++}}),{name:'AbortError'});assert.equal(spawned,0)
 const signal=new AbortController(),p=child(),handle=await openLiveMidi({routes,reserved:[],signal:signal.signal,spawnProcess:()=>p})
 signal.abort();assert.ok(p.kills.includes('SIGTERM'));let closed=false;handle.completion.then(()=>{closed=true});await flush();assert.equal(closed,false)
 p.stdout.write(JSON.stringify(state('stopped',{success:true}))+'\n');p.emit('close',0,null);await handle.completion
})
test('backing inspection validates native claims and owns failed/cancelled process closure',async()=>{
 for(const variant of ['success','cancel','format','missing']) {
  const p=child(),controller=new AbortController(),pending=backingMidiClaims({path:'/private/plan',format:'hybrid-arrangement',signal:controller.signal,spawnProcess:()=>p})
  const rejected=variant!=='success'?assert.rejects(pending):null
  p.stdout.write(JSON.stringify({kind:'reservations',schemaVersion:1,format:variant==='format'?'wrong':'hybrid-arrangement',...(variant==='missing'?{}:{reserved:[{destination:'42',scope:routes[0].scope}]})}))
  if(variant==='cancel'){controller.abort();assert.ok(p.kills.includes('SIGTERM'))}
  p.emit('close',0,null)
  if(rejected)await rejected;else assert.deepEqual(await pending,[{destination:'42',scope:routes[0].scope}])
 }
})
