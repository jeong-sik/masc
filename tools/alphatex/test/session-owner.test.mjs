import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { readFile } from 'node:fs/promises'
import { join, resolve, dirname } from 'node:path'
import { randomUUID } from 'node:crypto'
const flush=()=>new Promise(resolve=>setImmediate(resolve))

test('an attached snapshot exports to persistent project storage and drains the export before returning terminal ownership',async()=>{
  const process=new EventEmitter(),observed={exports:[],mkdir:[]}
  process.stdin=Object.assign(new EventEmitter(),{isTTY:true,isRaw:true,setRawMode(value){this.isRaw=value},resume(){},pause(){}})
  process.stdout=Object.assign(new EventEmitter(),{isTTY:true,columns:80,rows:24,write(){}})
  const timeline={duration:1,channels:0,midi:new Map(),manifest:{state:'recorded',input:{name:'Interface'}}}
  let completeExport
  const slot=`session-owner-${randomUUID()}`
  globalThis[slot]={process,join,resolve,randomUUID,safeText:String,emitKeypressEvents(){},
    mkdir:async path=>observed.mkdir.push(path),devices:async()=>({audio:[],midi:[]}),midiDestinations:async()=>[],readCapture:async()=>timeline,
    exportMidiClips:async(value,target)=>{observed.exports.push({value,target});await new Promise(resolve=>{completeExport=resolve});return [join(target,'keys.midi2')]},
    record(){throw new Error('Unexpected input acquisition')},spawn(){throw new Error('Unexpected player')},
    CaptureTimeline:class{},waveform(){throw new Error('Unexpected audio rendering')},
  }
  const source=(await readFile(new URL('../music-session.mjs',import.meta.url),'utf8')).replace(/^import .*$/gm,'')
  const prefix=`const {${Object.keys(globalThis[slot]).join(',')}}=globalThis[${JSON.stringify(slot)}];\n`
  const {viewSession}=await import('data:text/javascript;base64,'+Buffer.from(prefix+source).toString('base64'))
  const abort=new AbortController()
  const done=viewSession({directory:'/private/take',root:'/project/recordings',exportRoot:'/project/exports',embedded:true,signal:abort.signal})
  try {
    await flush();process.stdin.emit('keypress','e',{name:'e'});await flush()
    assert.equal(observed.exports.length,1)
    const {value,target}=observed.exports[0]
    assert.equal(value,timeline);assert.equal(dirname(target),'/project/exports');assert.deepEqual(observed.mkdir,[target])
    process.stdin.emit('keypress','e',{name:'e'});await flush();assert.equal(observed.exports.length,1)
    let returned=false;done.then(()=>{returned=true})
    process.stdin.emit('keypress','q',{name:'q'});await flush()
    assert.equal(returned,false);assert.equal(process.stdin.listenerCount('keypress'),0)
    completeExport();await done
    assert.equal(process.stdin.isRaw,true)
  } finally {abort.abort();completeExport?.();await done;delete globalThis[slot]}
})
