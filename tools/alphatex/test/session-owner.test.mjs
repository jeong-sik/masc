import { StatusReader } from '../status-reader.mjs'
import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { join, resolve, dirname } from 'node:path'
import { randomUUID } from 'node:crypto'
import { loadSubstituted } from './helpers/substituted-module.mjs'
const flush=()=>new Promise(resolve=>setImmediate(resolve))

test('an attached snapshot exports to persistent project storage and drains the export before returning terminal ownership',async()=>{
  const process=new EventEmitter(),observed={exports:[],mkdir:[]}
  process.stdin=Object.assign(new EventEmitter(),{isTTY:true,isRaw:true,setRawMode(value){this.isRaw=value},resume(){},pause(){}})
  process.stdout=Object.assign(new EventEmitter(),{isTTY:true,columns:80,rows:24,write(){}})
  const timeline={duration:1,channels:0,midi:new Map(),manifest:{state:'recorded',input:{name:'Interface'}}}
  let completeExport
  const substitutes = { StatusReader,join,resolve,randomUUID,safeText:String,emitKeypressEvents(){},
    mkdir:async path=>observed.mkdir.push(path),devices:async()=>({audio:[],midi:[]}),midiDestinations:async()=>[],readCapture:async()=>timeline,
    exportMidiClips:async(value,target)=>{observed.exports.push({value,target});await new Promise(resolve=>{completeExport=resolve});return [join(target,'keys.midi2')]},
    record(){throw new Error('Unexpected input acquisition')},spawn(){throw new Error('Unexpected player')},
    mkdtemp:async()=>{throw new Error('Unexpected temporary directory')},rm:async()=>{throw new Error('Unexpected removal')},
    tmpdir(){throw new Error('Unexpected temporary storage')},
    prepareCapturedPlayback:async()=>{throw new Error('Unexpected playback preparation')},prepareCapturedWave:async()=>{throw new Error('Unexpected wave preparation')},
    openPlayback(){throw new Error('Unexpected playback')},
    CaptureTimeline:class{},waveform(){throw new Error('Unexpected audio rendering')},
  }
  const { viewSession } = await loadSubstituted(new URL('../music-session.mjs', import.meta.url), substitutes, { globals: { process } })
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
  } finally {abort.abort();completeExport?.();await done}
})
