import assert from 'node:assert/strict'
import test from 'node:test'
import { EventEmitter } from 'node:events'
import { PassThrough } from 'node:stream'
import { readFile } from 'node:fs/promises'
import { join,resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { randomUUID } from 'node:crypto'
import { openPlayback } from '../playback.mjs'
const flush=()=>new Promise(resolve=>setImmediate(resolve))
async function scenario(paired) {
 const process=new EventEmitter(),observed={plans:[],options:[],spawn:[],removed:[],kills:[]}
 process.platform='darwin'
 process.stdin=Object.assign(new EventEmitter(),{isTTY:true,isRaw:false,setRawMode(value){this.isRaw=value},resume(){},pause(){}})
 process.stdout=Object.assign(new EventEmitter(),{isTTY:true,columns:80,rows:24,write(){}})
 const timeline={duration:1,channels:0,midi:new Map(),manifest:{state:'recorded',input:{name:'Synthetic'}}}
 const slot='capture-controller-'+randomUUID()
 const abort=new AbortController()
 globalThis[slot]={process,join,resolve,tmpdir,randomUUID,safeText:String,emitKeypressEvents(){},
  mkdtemp:async()=>'/private-owned-play',mkdir:async()=>{},rm:async path=>observed.removed.push(path),
  devices:async()=>({audio:[],midi:[]}),midiDestinations:async()=>[],readCapture:async()=>timeline,
  CaptureTimeline:class{},waveform(){throw Error('No waveform expected')},exportMidiClips(){throw Error('No export expected')},record(){throw Error('No recording expected')},spawn(){throw Error('Selected output must use native playback')},
  prepareCapturedPlayback:async(input,options)=>{observed.plans.push({input,options,kind:'paired'});return{path:'/private-owned-play/paired.json',format:'capture-session',midiOutput:'123',bindings:[{port:0,destination:'123'}]}},
  prepareCapturedWave:async(input,options)=>{observed.plans.push({input,options,kind:'wave'});return{path:'/private-owned-play/audio.wav',format:'wave'}},
  openPlayback(options){
   observed.options.push(options)
   const child=Object.assign(new EventEmitter(),{stdout:new PassThrough(),stderr:new PassThrough(),stdin:new PassThrough(),kill(signal){observed.kills.push(signal)}})
   const handle=openPlayback({...options,spawnProcess(executable,args){observed.spawn.push({executable,args});return child}})
   observed.child=child;return handle
  }
 }
 const source=(await readFile(new URL('../music-session.mjs',import.meta.url),'utf8')).replace(/^import .*$/gm,'')
 const prefix=`const {${Object.keys(globalThis[slot]).join(',')}}=globalThis[${JSON.stringify(slot)}];\n`
 const {viewSession}=await import('data:text/javascript;base64,'+Buffer.from(prefix+source).toString('base64'))
 const done=viewSession({directory:'/original-take',output:'selected-audio',...(paired?{midiOutput:'123'}:{}),signal:abort.signal})
 try {
  await flush();process.stdin.emit('keypress',' ',{name:'space'});await flush()
  assert.equal(observed.plans.length,1)
  assert.equal(observed.plans[0].kind,paired?'paired':'wave')
  assert.equal(observed.options.length,1)
  assert.equal(observed.options[0].output,'selected-audio')
  assert.deepEqual(observed.options[0].midiBindings,paired?[{port:0,destination:'123'}]:undefined)
  assert.equal(observed.spawn.length,1,'actual wrapper admits the selected capture route')
  assert.ok(observed.spawn[0].args.includes('--output'))
  assert.equal(observed.spawn[0].args.at(-1),'selected-audio')
  const event={kind:'playing',currentTime:0,duration:1,device:{id:'selected-audio',name:'Audio',outputs:2},loop:false,...(paired?{format:'capture-session',clock:{kind:'mach-host-time'},bindings:[{port:0,device:{kind:'midi',protocol:2,id:'123',name:'MIDI'}}]}:{})}
  observed.child.stdout.write(JSON.stringify(event)+'\n');await flush()
  let returned=false;done.then(()=>{returned=true})
  process.stdin.emit('keypress','q',{name:'q'});await flush()
  assert.equal(returned,false,'screen return awaits owned child close')
  assert.ok(observed.kills.includes('SIGTERM'))
  observed.child.stdout.write(JSON.stringify({...event,kind:'stopped',currentTime:1})+'\n');observed.child.stdout.end();observed.child.emit('close',0,null)
  await done
  assert.deepEqual(observed.removed,['/private-owned-play']);assert.equal(process.stdin.isRaw,false)

 }finally{abort.abort();if(observed.child){observed.child.stdout.end();observed.child.emit('close',0,null)}await done;delete globalThis[slot]}
}
test('captured session passes explicit source bindings through the actual playback protocol and drains its child',()=>scenario(true))
test('WAV-only session passes the selected audio output to native playback and drains its child',()=>scenario(false))
