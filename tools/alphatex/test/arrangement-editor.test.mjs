import { newProject, editProject, PPQ } from '../sequencer-project.mjs'
import { importPhraseDocument } from '../phrase-arrangement.mjs'
import { newEditor, editorCommand } from '../sequencer-editor.mjs'
import { practiceEnabled } from '../arrangement-practice.mjs'
import { liveMidiPlan } from '../live-midi.mjs'
import { calibrationSelection } from '../audio-calibration.mjs'
import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter, once } from 'node:events'
import { Worker } from 'node:worker_threads'
import { mkdtemp, readFile, writeFile, rename, rm } from 'node:fs/promises'
import { join, dirname, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { randomUUID } from 'node:crypto'
import { newArrangement, editArrangement, arrangementSchedule } from '../arrangement.mjs'
import { arrangementRoute, selectArrangementRoute, arrangementPlaybackRequest } from '../arrangement-playback.mjs'
import * as editorAPI from '../arrangement-editor.mjs'
import { loadArrangement } from '../arrangement-files.mjs'
import { importMidiSource, exportMidiSource, midiSourcePattern } from '../midi-source.mjs'
import { recordingEpoch } from '../arrangement-recording.mjs'
import { recordingCorrectionContext, recordingCorrectionCapture } from '../recording-correction.mjs'
import { calibrationMilliseconds, calibrationResidual, validateCalibrationCapture } from '../calibration-profile.mjs'

const waveAsset = { id: 'asset-1', name: 'Bass', kind: 'wave', file: `assets/${'a'.repeat(64)}.wav`, sha256: 'a'.repeat(64),
  metadata: { encoding: 'pcm', channels: 1, sampleRate: 48000, bitsPerSample: 16, validBits: 16, blockAlign: 2, frames: 48000 } }
const imported = project => ({ project: editArrangement(project, { kind: 'asset-add', asset: waveAsset }), asset: waveAsset.id })
function midi() {
  const data = [0,255,33,1,7,0,0xb0,1,88,0,0xe0,1,65,0,0x90,60,100,0x87,0x69,0x80,60,77,0,255,47,0]
  const header = Buffer.from('4d546864000000060000000103e94d54726b00000000','hex')
  header.writeUInt32BE(data.length, 18)
  return Buffer.concat([header,Buffer.from(data)])
}
test('region editor arranges typed WAV and expressive MIDI, trims, duplicates and restores immutable revisions', () => {
  let editor = editorAPI.arrangementImported(editorAPI.arrangementEditor(), imported(newArrangement()))
  const command = line => { editor = editorAPI.arrangementCommand(editor,line).editor }
  command('place asset-1 0'); command('trim 1200 4800'); command('repeat 3'); command('duplicate 4')
  const original = editor.project
  command('move 8'); command('undo'); assert.equal(editor.project,original)
  command('redo'); assert.equal(editor.project.clips[1].position,8*960)
  const source = importMidiSource(midi())
  editor = editorAPI.arrangementImported(editor,{project:editArrangement(editor.project,{kind:'asset-add',asset:{id:'asset-2',name:'Keys',kind:'midi',source}}),asset:'asset-2'})
  command('place asset-2 2'); assert.equal(editor.project.lanes.length,2)
  assert.equal(editor.project.clips[2].extent,1001)
  assert.deepEqual(Buffer.from(exportMidiSource(editor.project.assets[1].source)),midi())
  command('mute'); assert.equal(editor.project.lanes[1].muted,true)
  command('lane 1'); command('lane-remove'); assert.equal(editor.project.clips.length,1);assert.equal(editor.project.assets.length,2)
  command('undo'); assert.equal(editor.project.clips.length,3)
  const before=editor
  for(const line of ['trim -1 1','repeat 0','region-lane 99','tempo 0','place missing 0','region asset-1 0 48000 1'])assert.throws(()=>editorAPI.arrangementCommand(editor,line))
  assert.equal(editor,before)
  assert.deepEqual(editorAPI.arrangementCommand(editor,'import-wave /music/My  take.wav').effect,{kind:'import-wave',path:'/music/My  take.wav'})
})

test('actual IO worker preserves sources in redo history when saving to a different asset root',async()=>{
  const directory=await mkdtemp(join(tmpdir(),'masc-arrange-worker-')),worker=new Worker(new URL('../arrangement-worker.mjs',import.meta.url))
  let id=0
  const request=async value=>{const response=once(worker,'message');worker.postMessage({...value,id:++id});const [message]=await response;assert.equal(message.ok,true,message.error);return message.result}
  try{
    const bytes=Buffer.alloc(44+4800*2);bytes.write('RIFF');bytes.writeUInt32LE(bytes.length-8,4);bytes.write('WAVEfmt ',8);bytes.writeUInt32LE(16,16);bytes.writeUInt16LE(1,20);bytes.writeUInt16LE(1,22);bytes.writeUInt32LE(48000,24);bytes.writeUInt32LE(96000,28);bytes.writeUInt16LE(2,32);bytes.writeUInt16LE(16,34);bytes.write('data',36);bytes.writeUInt32LE(bytes.length-44,40)
    const input=join(directory,'take.wav'),path=join(directory,'old','song.json');await writeFile(input,bytes)
    const imported=await request({kind:'import-wave',project:newArrangement(),path:input,projectPath:path})
    const retained=imported.project.assets,empty=newArrangement(),copy=join(directory,'copy','song.json')
    const revision=await request({kind:'save',project:empty,path:copy,revision:null,sourceRoot:dirname(path),retainedAssets:retained})
    await rename(dirname(path),join(directory,'old-removed'))
    const editor=editorAPI.arrangementCommand(editorAPI.arrangementImported(editorAPI.arrangementEditor(empty),imported),'place asset-1 4').editor
    await request({kind:'save',project:editor.project,path:copy,revision,sourceRoot:dirname(copy)})
    assert.deepEqual((await loadArrangement(copy)).project,editor.project)
    assert.deepEqual(await readFile(input),bytes)
    assert.deepEqual(await readFile(join(dirname(copy),retained[0].file)),bytes)
    const midiPath=join(directory,'source.mid');await writeFile(midiPath,midi())
    const m=await request({kind:'import-midi',path:midiPath,project:editor.project})
    assert.deepEqual(Buffer.from(exportMidiSource(m.project.assets[1].source)),midi())
    assert.equal(m.project.assets[1].source.kind,'midi-source')
  }finally{await worker.terminate();await rm(directory,{recursive:true,force:true})}
})

const flush=()=>new Promise(resolve=>setImmediate(resolve))
async function controller(options={}){
  const observed={requests:[],saved:[],recovered:[],terminated:false,players:[],removed:[],takes:[],captures:[],monitors:[],live:[],liveAttempts:[],claims:[],calibrations:[],writes:[],phrases:[]},process=new EventEmitter()
  const admitLive=options.admitLive, heldPlaybackReady=options.playbackReady
  process.stdin=Object.assign(new EventEmitter(),{isTTY:true,isRaw:false,setRawMode(value){this.isRaw=value},resume(){},pause(){}})
  process.stdout=Object.assign(new EventEmitter(),{isTTY:true,columns:100,rows:24,write(){}});process.stderr={write(){}}
  let owner
  class OwnedWorker extends EventEmitter{
    constructor(){super();owner=this}
    postMessage(job){
      observed.requests.push(job)
      if(job.kind==='save'&&!options.holdSave)queueMicrotask(()=>{
        if(typeof options.failSave==='function'?options.failSave(job):options.failSave)this.emit('message',{id:job.id,ok:false,error:'Publication outcome unavailable'})
        else {observed.saved.push(job);this.emit('message',{id:job.id,ok:true,result:'revision'})}
      })
    }
    async terminate(){observed.terminated=true}
  }
  const slot=`arrange-controller-${randomUUID()}`
  globalThis[slot]={process,Worker:OwnedWorker,arrangementSchedule,arrangementRoute,selectArrangementRoute,arrangementPlaybackRequest,...editorAPI,join,dirname,resolve,tmpdir,randomUUID,
    practiceEnabled, emitKeypressEvents(){},safeText:String,recordingEpoch,recordingCorrectionContext,recordingCorrectionCapture,calibrationMilliseconds,calibrationResidual,validateCalibrationCapture,
    liveMidiPlan, calibrationSelection, midiDestinations:async()=>[],
    measureAudioCalibration(options){
      let finish,reject;const completion=new Promise((yes,no)=>{finish=yes;reject=no})
      observed.calibrations.push({options,finish,reject});return completion
    },
    backingMidiClaims:async value=>{observed.claims.push(value);await options.inspect?.(value);return options.backingClaims??[]},
    openLiveMidi:async options=>{
      observed.liveAttempts.push(options);admitLive?.(options)
      let finish,reject;const completion=new Promise((yes,no)=>{finish=yes;reject=no})
      const info={kind:"monitoring",bindings:options.routes.map(route=>({source:route.source,device:{id:route.destination,name:"Instrument"},scope:route.scope}))}
      const entry={options,finish,reject,stops:0};observed.live.push(entry);options.onEvent(info)
      return {ready:Promise.resolve(info),completion,stop(){entry.stops++}}
    },
    mkdir:options.mkdir??(async()=>{}), devices:async()=>({audio:[],midi:[]}),
    monitorInput(options){
      let finish,reject
      const completion=new Promise((yes,no)=>{finish=yes;reject=no})
      const entry={options,stops:0,finish,reject};observed.monitors.push(entry)
      return{completion,stop(){entry.stops++}}
    },
    record(options){
      let finish,reject
      const completion=new Promise((yes,no)=>{finish=yes;reject=no})
      const entry={options,stops:0,finish(value){finish(value?.manifest ? value : {manifest:{input:{id:options.input},channels:2,sampleRate:48000,monitoring:{state:options.monitorOutput ? 'active':'off'}}})},reject}
      observed.captures.push(entry)
      return{completion,stop(){entry.stops++}}
    },
    openSequencer(options){
      let finish;const result=new Promise(resolve=>{finish=resolve})
      observed.phrases.push({options,finish});return result
    },
    viewSession(options){
      let finish
      const completion=new Promise(resolve=>{finish=resolve})
      observed.takes.push({options,finish});return completion
    },
    verifyArrangementAssets:async()=>new Map(),
    loadArrangement:async()=>{throw new Error('Unexpected load')},
    mkdtemp:async()=>'/owned-recovery',writeFile:async(path,data,options)=>{observed.writes.push({path,data,options})},rm:async path=>{observed.removed.push(path)},openPlayback(options){
      let resolve,reject
      const completion=new Promise((yes,no)=>{resolve=yes;reject=no})
      const event=(kind,currentTime=0)=>{const value={kind,currentTime,duration:10,device:{id:'output',name:'Output',outputs:2},loop:false,
        clock:{kind:'mach-host-time',anchor:'9007199254740993123',position:0,numer:125,denom:3}};options.onEvent(value);return value}
      const handle={recordingEpoch:async()=>({kind:'playing',duration:10,loop:false,device:{id:'output',outputs:2},clock:{kind:'mach-host-time',anchor:'9007199254740993123',position:0,numer:125,denom:3}}),completion,ready:heldPlaybackReady??Promise.resolve(),stop(){entry.commands.push('stop')},terminate(){entry.commands.push('terminate')},pause(){entry.commands.push('pause');event('paused')},resume(){entry.commands.push('resume');event('playing')},status(){entry.commands.push('status')},seek(seconds){entry.commands.push(['seek',seconds])}}
      const entry={options,handle,commands:[],finish(){resolve(event('stopped'))},reject,event}
      observed.players.push(entry);queueMicrotask(()=>event('playing'));return handle
    },
    saveProject:async()=>{throw new Error('Unexpected unverified recovery')},
    saveArrangement:async(path,project,revision,extra)=>{observed.recovered.push({path,project,revision,...extra})},
  }
  const source=(await readFile(new URL('../arrangement-tui.mjs',import.meta.url),'utf8')).replace(/^import .*$/gm,'')
    .replace("new URL('./arrangement-worker.mjs', import.meta.url)","new URL('file:///worker')")
    .replace("await import('./sequencer-tui.mjs')",'await Promise.resolve({viewSequencer:openSequencer})')
  const prefix=`const {${Object.keys(globalThis[slot]).join(',')}}=globalThis[${JSON.stringify(slot)}];\n`
  const {viewArrangement}=await import('data:text/javascript;base64,'+Buffer.from(prefix+source).toString('base64'))
  const abort=new AbortController(),done=viewArrangement({root:'/synthetic',signal:abort.signal}).finally(()=>{delete globalThis[slot]})
  await flush()
  const key=(name,text='',extra={})=>process.stdin.emit('keypress',text,{name,...extra})
  return {observed,process,done,abort,key,worker:owner,command(line){key(undefined,':');key(undefined,line);key('return')}}
}

test('controller serializes import with admitted clip edits and saves final decisions on close',async()=>{
  const view=await controller()
  view.command('import-wave /music/My  take.wav');await flush()
  const job=view.observed.requests.find(job=>job.kind==='import-wave')
  assert.equal(job.path,'/music/My  take.wav')
  view.command('place asset-1 2');view.command('trim 1200 4800');view.command('duplicate 8')
  view.worker.emit('message',{id:job.id,ok:true,result:imported(job.project)});await flush()
  view.key('q');view.command('title Too late');await view.done
  const saved=view.observed.saved.at(-1).project
  assert.equal(saved.clips.length,2);assert.equal(saved.clips[1].position,8*960)
  assert.deepEqual(saved.clips.map(clip=>[clip.offset,clip.extent]),[[1200,4800],[1200,4800]])
  assert.notEqual(saved.title,'Too late');assert.equal(view.process.stdin.isRaw,false);assert.equal(view.observed.terminated,true)
})

test('close cancels an active import, waits for its cleanup, drains admitted edits and rejects late adoption',async()=>{
  const view=await controller()
  view.command('import-wave /music/take.wav');await flush()
  const job=view.observed.requests[0]
  view.command('title Kept before close');view.key('q');await flush()
  let returned=false;view.done.then(()=>{returned=true})
  assert.equal(returned,false);assert.equal(view.observed.requests.at(-1).kind,'cancel')
  view.worker.emit('message',{id:job.id,ok:false,cancelled:true,error:'Cancelled'})
  await view.done
  const saved=view.observed.saved.at(-1).project
  assert.equal(saved.title,'Kept before close');assert.equal(saved.assets.length,0)
  assert.equal(view.process.stdin.isRaw,false);assert.equal(view.observed.terminated,true)
})

test('uncertain save is retained at a different recovery path without retrying the original publication',async()=>{
  const view=await controller({failSave:true})
  view.command('title Keep this');view.key('s');await flush();view.key('q');await view.done
  assert.equal(view.observed.requests.filter(job=>job.kind==='save').length,1)
  assert.equal(view.observed.recovered.length,1)
  assert.equal(view.observed.recovered[0].project.title,'Keep this')
  assert.notEqual(view.observed.recovered[0].path,view.observed.requests[0].path)
  assert.equal(view.process.stdin.isRaw,false);assert.equal(view.observed.terminated,true)
})

test('uncertain publications on two paths remain independently fenced during close',async()=>{
  const view=await controller({failSave:true})
  view.command('title Keep both failure histories');view.key('s');await flush()
  const original=view.observed.requests.find(job=>job.kind==='save').path,alternative='/synthetic/alternative.json'
  view.command(`save-as ${alternative}`);await flush()
  view.key('q');await view.done
  assert.deepEqual(view.observed.requests.filter(job=>job.kind==='save').map(job=>job.path),[original,alternative])
  assert.equal(view.observed.recovered.length,1)
  assert.ok(![original,alternative].includes(view.observed.recovered[0].path))
  assert.equal(view.observed.recovered[0].project.title,'Keep both failure histories')
  assert.equal(view.process.stdin.isRaw,false)
})

test('a successful explicit save clears that path failure before subsequent close autosave',async()=>{
  let attempts=0
  const view=await controller({failSave:()=>++attempts===1})
  view.command('title First');view.key('s');await flush()
  view.key('s');await flush()
  view.command('title After successful retry');view.key('q');await view.done
  const requests=view.observed.requests.filter(job=>job.kind==='save')
  assert.equal(requests.length,3)
  assert.ok(requests.every(job=>job.path===requests[0].path))
  assert.equal(view.observed.saved.at(-1).project.title,'After successful retry')
  assert.equal(view.observed.recovered.length,0)
  assert.equal(view.process.stdin.isRaw,false)
})

test('worker exit during close settles its active job and drains admitted edits before recovery',async()=>{
  const view=await controller()
  view.command('import-wave /music/take.wav');await flush()
  view.command('title Retained after worker exit');view.key('q');await flush()
  assert.equal(view.observed.requests.at(-1).kind,'cancel')
  view.worker.emit('exit',1)
  await view.done
  assert.equal(view.observed.requests.filter(job=>job.kind==='save').length,0)
  assert.equal(view.observed.recovered.length,1)
  assert.equal(view.observed.recovered[0].project.title,'Retained after worker exit')
  assert.equal(view.observed.recovered[0].project.assets.length,0)
  assert.equal(view.process.stdin.isRaw,false)
  assert.equal(view.observed.terminated,true)
})

test('worker exit with no active job rejects an already admitted save after input closes',async()=>{
  const view=await controller()
  view.command('title Accepted before worker exit');view.key('s');view.key('q')
  await Promise.resolve()
  assert.equal(view.process.stdin.listenerCount('keypress'),0)
  assert.equal(view.observed.requests.filter(job=>job.kind==='save').length,0)
  view.worker.emit('exit',1)
  await view.done
  assert.equal(view.observed.requests.filter(job=>job.kind==='save').length,0)
  assert.equal(view.observed.recovered.length,1)
  assert.equal(view.observed.recovered[0].project.title,'Accepted before worker exit')
  assert.equal(view.process.stdin.isRaw,false)
  assert.equal(view.observed.terminated,true)
})


async function primeWave(view) {
  view.command('import-wave /music/take.wav'); await flush()
  const job=view.observed.requests.find(job=>job.kind==='import-wave')
  view.worker.emit('message',{id:job.id,ok:true,result:imported(job.project)}); await flush()
  view.command('place asset-1 0'); await flush()
}

test('WAV preparation stays cancellable and a late result cannot launch playback',async()=>{
  const view=await controller();await primeWave(view)
  view.key('space');await flush()
  const request=view.observed.requests.find(job=>job.kind==='prepare-wave')
  assert.ok(request)
  view.key('space');await flush()
  assert.ok(view.observed.requests.some(job=>job.kind==='cancel'&&job.request===request.id))
  view.worker.emit('message',{id:request.id,ok:true,result:{path:'/owned-recovery/play-1/plan.json',format:'wave-arrangement'}})
  await flush();assert.equal(view.observed.players.length,0)
  view.key('q');await view.done
  assert.ok(view.observed.removed.includes('/owned-recovery/play-1'))
})

test('arrangement owns one player through pause, seek, resume and close cleanup',async()=>{
  const view=await controller();await primeWave(view)
  view.key('space');await flush()
  const request=view.observed.requests.find(job=>job.kind==='prepare-wave')
  view.worker.emit('message',{id:request.id,ok:true,result:{path:'/owned-recovery/play-1/plan.json',format:'wave-arrangement'}})
  await flush();const player=view.observed.players[0]
  assert.equal(player.options.format,'wave-arrangement')
  view.key('space');await flush();view.command('seek 2');await flush();view.key('space');await flush()
  assert.ok(player.commands.includes('pause'));assert.ok(player.commands.includes('resume'))
  assert.ok(player.commands.some(command=>Array.isArray(command)&&command[0]==='seek'&&command[1]===1.2))
  view.key('q');await flush()
  let returned=false;view.done.then(()=>{returned=true});await flush();assert.equal(returned,false)
  assert.ok(player.commands.includes('stop'));assert.ok(player.commands.includes('terminate'))
  assert.ok(!view.observed.removed.includes('/owned-recovery/play-1'))
  player.finish();await view.done
  assert.equal(view.observed.players.length,1);assert.equal(view.process.stdin.isRaw,false)
  assert.ok(view.observed.removed.includes('/owned-recovery/play-1'))
})

test('document mutation stops the admitted playback revision while cursor motion keeps it',async()=>{
  const view=await controller();await primeWave(view);view.key('space');await flush()
  const job=view.observed.requests.find(job=>job.kind==='prepare-wave')
  view.worker.emit('message',{id:job.id,ok:true,result:{path:'/owned-recovery/play-1/plan.json',format:'wave-arrangement'}})
  await flush();const player=view.observed.players[0]
  view.command('cursor 4');await flush();assert.ok(!player.commands.includes('stop'))
  view.command('title New revision');await flush();assert.ok(player.commands.includes('stop'))
  player.finish();view.key('q');await view.done
  assert.equal(view.observed.saved.at(-1).project.title,'New revision')
})

async function closeController(view) {
  view.abort.abort()
  for (const job of view.observed.requests.filter(job=>['prepare-wave','prepare-midi','prepare-mixed','prepare-take','prepare-phrase','import-wave','import-midi','import-take'].includes(job.kind))) {
    view.worker.emit('message',{id:job.id,ok:false,cancelled:true,error:'Cancelled'})
  }
  for (const player of view.observed.players) player.finish()
  for (const take of view.observed.takes) take.finish()
  for (const phrase of view.observed.phrases) phrase.finish({changed:false})
  await view.done
}
test('explicit MIDI selection cannot route a WAV arrangement to default audio; choosing audio clears MIDI bindings',async()=>{
  const view=await controller()
  try {
    view.command('import-wave /music/take.wav');await flush();const importedJob=view.observed.requests.find(job=>job.kind==='import-wave')
    view.worker.emit('message',{id:importedJob.id,ok:true,result:imported(importedJob.project)});await flush()
    view.command('place asset-1 0');view.command('midi-output 42');view.key('space');await flush()
    assert.equal(view.observed.requests.filter(job=>job.kind==='prepare-wave'||job.kind==='prepare-midi').length,0)
    view.command('output explicit-audio');view.key('space');await flush()
    const job=view.observed.requests.find(job=>job.kind==='prepare-wave');assert.ok(job)
    view.worker.emit('message',{id:job.id,ok:true,result:{path:'/owned-recovery/play-1/plan.json',format:'wave-arrangement'}});await flush()
    assert.equal(view.observed.players[0].options.output,'explicit-audio')
    assert.equal(view.observed.players[0].options.midiOutput,undefined)
  } finally { await closeController(view) }
})
test('MIDI asset bindings survive prepare and own pause/seek/resume; route changes stop the admitted owner',async()=>{
  const view=await controller()
  try {
    view.command('import-midi /music/take.mid');await flush();const job=view.observed.requests.find(job=>job.kind==='import-midi')
    const asset={id:'asset-1',name:'Keys',kind:'midi',source:importMidiSource(midi())}
    view.worker.emit('message',{id:job.id,ok:true,result:{project:editArrangement(job.project,{kind:'asset-add',asset}),asset:asset.id}});await flush()
    view.command('place asset-1 0');view.command('output explicit-audio');view.key('space');await flush()
    assert.equal(view.observed.requests.filter(job=>job.kind==='prepare-midi').length,0)
    view.command('midi-port asset-1 7 42');view.key('space');await flush()
    const prepared=view.observed.requests.find(job=>job.kind==='prepare-midi');assert.ok(prepared)
    assert.deepEqual(prepared.portBindings,[{asset:'asset-1',port:7,destination:'42'}])
    view.worker.emit('message',{id:prepared.id,ok:true,result:{path:'/owned-recovery/play-2/plan.json',format:'midi-arrangement',midiOutput:'42',bindings:[{port:0,destination:'42'}]}});await flush()
    const player=view.observed.players[0];assert.equal(player.options.midiOutput,'42');assert.equal(player.options.output,undefined)
    assert.deepEqual(player.options.midiBindings,[{port:0,destination:'42'}])
    view.key('space');await flush();view.command('seek .5');await flush();view.key('space');await flush()
    assert.deepEqual(player.commands.slice(0,3),['pause',['seek',.3],'resume'])
    view.command('midi-output 43');await flush();assert.ok(player.commands.includes('stop'))
  } finally { await closeController(view) }
})

async function primeMixed(view) {
  await primeWave(view)
  view.command('import-midi /music/keys.mid'); await flush()
  const job=view.observed.requests.find(job=>job.kind==='import-midi')
  const asset={id:'asset-2',name:'Keys',kind:'midi',source:importMidiSource(midi())}
  view.worker.emit('message',{id:job.id,ok:true,result:{project:editArrangement(job.project,{kind:'asset-add',asset}),asset:asset.id}}); await flush()
  view.command('place asset-2 0'); await flush()
  view.command('mixed-output explicit-audio');view.command('midi-port asset-2 7 42'); await flush()
}
test('mixed controller pins paired outputs and owns one player through pause, seek, resume and output replacement',async()=>{
  const view=await controller()
  try {
    await primeMixed(view);view.key('space');await flush()
    const job=view.observed.requests.find(job=>job.kind==='prepare-mixed');assert.ok(job)
    assert.equal(job.output,'explicit-audio');assert.deepEqual(job.portBindings,[{asset:'asset-2',port:7,destination:'42'}])
    const result={path:'/owned-recovery/play-mixed/plan.json',format:'mixed-arrangement',midiOutput:'42',bindings:[{port:0,destination:'42'}]}
    view.worker.emit('message',{id:job.id,ok:true,result});await flush()
    const player=view.observed.players[0]
    assert.equal(player.options.output,'explicit-audio');assert.equal(player.options.midiOutput,'42');assert.equal(player.options.format,'mixed-arrangement')
    view.key('space');await flush();view.command('seek .5');await flush();view.key('space');await flush()
    assert.deepEqual(player.commands.slice(0,3),['pause',['seek',.3],'resume'])
    view.command('midi-output 43');await flush();assert.ok(player.commands.includes('stop'))
    player.finish();view.key('space');await flush()
    const next=view.observed.requests.filter(job=>job.kind==='prepare-mixed').at(-1)
    assert.equal(next.output,'explicit-audio');assert.equal(next.midiOutput,'43');assert.deepEqual(next.portBindings,[])
  } finally { await closeController(view) }
})
test('mixed preparation cancellation refuses a late combined plan and cleans its complete source root',async()=>{
  const view=await controller()
  try {
    await primeMixed(view);view.key('space');await flush()
    const job=view.observed.requests.find(job=>job.kind==='prepare-mixed');assert.ok(job)
    view.command('stop');await flush()
    assert.ok(view.observed.requests.some(value=>value.kind==='cancel'&&value.request===job.id))
    view.worker.emit('message',{id:job.id,ok:true,result:{path:'/owned-recovery/mixed-late/plan.json',format:'mixed-arrangement',midiOutput:'42',bindings:[{port:0,destination:'42'}]}})
    await flush();assert.equal(view.observed.players.length,0)
    assert.ok(view.observed.removed.includes('/owned-recovery/mixed-late'))
  } finally { await closeController(view) }
})

async function primeCapture(view) {
  view.command('import-take /music/My  capture');await flush()
  const job=view.observed.requests.find(job=>job.kind==='import-take')
  assert.equal(job.path,'/music/My  capture')
  const asset={id:'capture-1',name:'Take',kind:'capture',parts:Object.fromEntries(['manifest','audio','audioBlocks','midi'].map((role,index)=>{
    const sha256=String(index+1).repeat(64);return [role,{file:`assets/${sha256}.${role==='audio'?'wav':'capture'}`,sha256}]
  })),midiTime:{first:'200',last:'200'},manifest:{schemaVersion:1,state:'recorded',failure:null,audio:'audio.wav',audioBlocks:'audio-blocks.jsonl',midi:'midi.ump.jsonl',
    sampleRate:48000,channels:1,audioFrames:'4800',midiPacketCount:'1',input:{id:'audio',name:'Interface'},midiSources:[{id:'keys',name:'Keys'}],
    clock:{kind:'mach-host-time',numer:1,denom:1,requestedStart:'100',firstAudioHostTime:'200'}}}
  view.worker.emit('message',{id:job.id,ok:true,result:{project:editArrangement(job.project,{kind:'asset-add',asset}),asset:asset.id}});await flush()
  return asset
}
test('captured-region commands persist typed bounds and select paired preparation with complete project ownership',async()=>{
  const view=await controller()
  try {
    await primeWave(view);await primeCapture(view)
    view.key('return','',{shift:true});await flush()
    assert.equal(view.observed.takes.length,0)
    view.command('trim-time .0000001 .05');view.command('repeat 2000000');view.command('duplicate 8');view.command('undo');view.command('redo')
    view.command('save');await flush()
    const project=view.observed.saved.at(-1).project,captured=project.clips.filter(clip=>clip.asset==='capture-1')
    assert.equal(captured.length,2);assert.deepEqual(captured.map(clip=>[clip.offset,clip.extent,clip.repeat]),[['100','50000000',2000000],['100','50000000',2000000]])
    assert.equal(project.lanes.find(lane=>lane.id===captured[0].lane).kind,'capture')
    const before=view.observed.requests.length;view.key('space');await flush()
    assert.equal(view.observed.requests.length,before,'no preparation or player can omit audible capture data')
    assert.equal(view.observed.players.length,0)
    view.command('mixed-output audio');view.command('midi-source capture-1 keys 42');view.key('space');await flush()
    const paired=view.observed.requests.at(-1);assert.equal(paired.kind,'prepare-capture')
    assert.deepEqual(paired.sourceBindings,[{asset:'capture-1',source:'keys',destination:'42'}]);assert.deepEqual(paired.project,project)
    view.command('stop');await flush()
    view.worker.emit('message',{id:paired.id,ok:true,result:{path:'/owned-recovery/paired-late/plan.json',format:'capture-arrangement',midiOutput:'42',bindings:[{port:0,destination:'42'}]}});await flush()
    assert.equal(view.observed.players.length,0);assert.ok(view.observed.removed.includes('/owned-recovery/paired-late'))
    view.command('mute');view.key('space');await flush()
    const prepare=view.observed.requests.at(-1);assert.equal(prepare.kind,'prepare-wave')
    assert.equal(prepare.project.lanes.find(lane=>lane.kind==='capture').muted,true)
    view.worker.emit('message',{id:prepare.id,ok:false,cancelled:true,error:'Cancelled'});await flush()
  } finally {await closeController(view)}
})
test('captured source viewer waits for playback, borrows input and returns ownership before removing its snapshot',async()=>{
  const view=await controller()
  try {
    await primeWave(view);view.key('space');await flush()
    const play=view.observed.requests.find(job=>job.kind==='prepare-wave')
    view.worker.emit('message',{id:play.id,ok:true,result:{path:'/owned-recovery/play/plan.json',format:'wave-arrangement'}});await flush()
    const player=view.observed.players[0];await primeCapture(view)
    view.key('return');await flush()
    const job=view.observed.requests.find(job=>job.kind==='prepare-take')
    assert.equal(job.asset,'capture-1');assert.ok(player.commands.includes('stop'))
    view.worker.emit('message',{id:job.id,ok:true,result:{directory:'/owned-recovery/take-1'}});await flush()
    assert.equal(view.observed.takes.length,0)
    player.finish();await flush()
    const take=view.observed.takes[0]
    assert.equal(take.options.directory,'/owned-recovery/take-1');assert.equal(take.options.embedded,true)
    assert.equal(take.options.exportRoot,'/synthetic/exports');assert.equal(take.options.root,'/synthetic/recordings')
    assert.equal(view.process.stdin.listenerCount('keypress'),0)
    view.command('title Not admitted by parent');await flush()
    assert.ok(!view.observed.removed.includes(take.options.directory))
    take.finish();await flush()
    assert.equal(view.process.stdin.listenerCount('keypress'),1)
    assert.ok(view.observed.removed.includes(take.options.directory))
    view.command('title Returned');await flush();view.key('q');await view.done
    assert.equal(view.observed.saved.at(-1).project.title,'Returned')
  } finally {await closeController(view)}
})
test('root cancellation aborts the take owner and drains it before deleting sources or restoring raw input',async()=>{
  const view=await controller()
  try {
    await primeCapture(view);view.command('open-take');await flush()
    const job=view.observed.requests.find(job=>job.kind==='prepare-take')
    view.worker.emit('message',{id:job.id,ok:true,result:{directory:'/owned-recovery/take-2'}});await flush()
    const take=view.observed.takes[0];let done=false;view.done.then(()=>{done=true})
    view.abort.abort();await flush()
    assert.equal(take.options.signal.aborted,true);assert.equal(done,false)
    assert.ok(!view.observed.removed.includes(take.options.directory));assert.equal(view.process.stdin.isRaw,true)
    take.finish();await view.done
    assert.ok(view.observed.removed.includes(take.options.directory));assert.equal(view.process.stdin.isRaw,false)
    assert.equal(view.process.stdin.listenerCount('keypress'),0)
  } finally {await closeController(view)}
})
test('cancelled take preparation cannot open a late snapshot and removes its owned copy',async()=>{
  const view=await controller()
  try {
    await primeCapture(view);view.command('open-take');await flush()
    const job=view.observed.requests.find(job=>job.kind==='prepare-take')
    view.command('stop');await flush()
    assert.ok(view.observed.requests.some(value=>value.kind==='cancel'&&value.request===job.id))
    view.worker.emit('message',{id:job.id,ok:true,result:{directory:'/owned-recovery/take-late'}});await flush()
    assert.equal(view.observed.takes.length,0);assert.ok(view.observed.removed.includes('/owned-recovery/take-late'))
  } finally {await closeController(view)}
})
test('Save As retains all captured parts in redo history before moving the project source root',async()=>{
  const view=await controller()
  try {
    const asset=await primeCapture(view);view.command('undo');await flush()
    view.command('save-as /moved/song.json');await flush()
    const save=view.observed.saved.at(-1)
    assert.equal(save.project.assets.length,0);assert.equal(save.retainedAssets.length,1)
    assert.deepEqual(save.retainedAssets[0].parts,asset.parts)
    view.command('redo');view.command('open-take');await flush()
    const job=view.observed.requests.find(job=>job.kind==='prepare-take')
    assert.equal(job.sourceRoot,'/moved');assert.deepEqual(job.project.assets[0],asset)
    view.worker.emit('message',{id:job.id,ok:false,cancelled:true,error:'Cancelled'});await flush()
  } finally {await closeController(view)}
})

test('already admitted take requests wait for the current leaf lifetime, including a delayed save between them',async()=>{
  const view=await controller({holdSave:true})
  try {
    await primeCapture(view)
    view.command('open-take');view.command('save');view.command('open-take');await flush()
    const first=view.observed.requests.find(job=>job.kind==='prepare-take'),save=view.observed.requests.find(job=>job.kind==='save')
    assert.ok(first&&save)
    view.worker.emit('message',{id:first.id,ok:true,result:{directory:'/owned-recovery/take-first'}});await flush()
    assert.equal(view.observed.takes.length,1)
    view.worker.emit('message',{id:save.id,ok:true,result:'revision'});await flush()
    assert.equal(view.observed.requests.filter(job=>job.kind==='prepare-take').length,1)
    const prior=view.observed.takes[0]
    assert.equal(prior.options.signal.aborted,false);assert.equal(view.observed.takes.length,1)
    assert.ok(!view.observed.removed.includes(prior.options.directory))
    prior.finish();await flush()
    const second=view.observed.requests.filter(job=>job.kind==='prepare-take')[1];assert.ok(second)
    view.worker.emit('message',{id:second.id,ok:true,result:{directory:'/owned-recovery/take-second'}});await flush()
    assert.equal(view.observed.takes.length,2)
    const current=view.observed.takes[1]
    assert.equal(current.options.signal.aborted,false);assert.equal(view.process.stdin.listenerCount('keypress'),0)
    assert.ok(view.observed.removed.includes(prior.options.directory))
    view.abort.abort();await flush();assert.equal(current.options.signal.aborted,true)
    current.finish();await view.done
    assert.equal(view.process.stdin.listenerCount('keypress'),0)
  } finally {
    for(const job of view.observed.requests.filter(job=>job.kind==='save'))view.worker.emit('message',{id:job.id,ok:true,result:'revision'})
    await closeController(view)
  }
})


test('ordinary paired capture play passes source bindings and drains native playback before removing its private snapshots',async()=>{
  const view=await controller()
  try {
    await primeCapture(view);view.key('return','',{shift:true});view.command('mixed-output selected-audio');view.command('midi-source capture-1 keys -42');view.key('space');await flush()
    const prepare=view.observed.requests.find(job=>job.kind==='prepare-capture');assert.ok(prepare)
    assert.deepEqual(prepare.sourceBindings,[{asset:'capture-1',source:'keys',destination:'-42'}])
    view.worker.emit('message',{id:prepare.id,ok:true,result:{path:'/owned-recovery/paired/plan.json',format:'capture-arrangement',midiOutput:'-42',bindings:[{port:0,destination:'-42'}]}});await flush()
    const player=view.observed.players[0];assert.equal(player.options.format,'capture-arrangement');assert.equal(player.options.output,'selected-audio')
    assert.deepEqual(player.options.midiBindings,[{port:0,destination:'-42'}])
    view.command('stop');await flush();assert.ok(player.commands.includes('stop'));assert.ok(!view.observed.removed.includes('/owned-recovery/paired'))
    player.finish();await flush();assert.ok(view.observed.removed.includes('/owned-recovery/paired'))
  } finally {await closeController(view)}
})


test('ordinary hybrid TUI playback retains every audible lane and both selected stream protocols',async()=>{
  const view=await controller()
  try {
    await primeMixed(view);await primeCapture(view);view.key('return','',{shift:true})
    view.command('midi-output 42');view.command('mixed-output audio');view.command('midi-port asset-2 7 43');view.command('midi-source capture-1 keys 44');view.key('space');await flush()
    const prepare=view.observed.requests.find(job=>job.kind==='prepare-capture');assert.ok(prepare)
    assert.equal(prepare.project.clips.length,3);assert.equal(prepare.midiOutput,'42')
    assert.deepEqual(prepare.portBindings,[{asset:'asset-2',port:7,destination:'43'}])
    const bindings=[{port:0,destination:'43',protocol:1},{port:1,destination:'44',protocol:2}]
    view.worker.emit('message',{id:prepare.id,ok:true,result:{path:'/owned-recovery/hybrid/plan.json',format:'hybrid-arrangement',midiOutput:'43',bindings}});await flush()
    const player=view.observed.players[0];assert.equal(player.options.format,'hybrid-arrangement');assert.deepEqual(player.options.midiBindings,bindings)
    view.command('stop');await flush();assert.ok(player.commands.includes('stop'));assert.ok(!view.observed.removed.includes('/owned-recovery/hybrid'))
    player.finish();await flush();assert.ok(view.observed.removed.includes('/owned-recovery/hybrid'))
  }finally{await closeController(view)}
})

test('recording finalization owns transport mutation, imports once, and preserves failed takes',async()=>{
 const view=await controller();await primeWave(view)
 view.command('input interface');view.command('midi-input keys');view.key('space');await flush()
 const prepare=view.observed.requests.find(job=>job.kind==='prepare-wave')
 view.worker.emit('message',{id:prepare.id,ok:true,result:{path:'/owned/play/plan.json',format:'wave-arrangement'}});await flush()
 view.command('record');await flush()
 const capture=view.observed.captures[0],player=view.observed.players[0]
 assert.equal(capture.options.input,'interface');assert.equal(capture.options.midi,'keys')
 view.key('space');await flush()
 assert.ok(capture.stops>0);assert.ok(!player.commands.includes('pause'))
 capture.finish({});await flush()
 const attach=view.observed.requests.find(job=>job.kind==='attach-recording')
 assert.ok(attach);assert.equal(attach.epoch.clock.anchor,'9007199254740993123')
 view.worker.emit('message',{id:attach.id,ok:false,error:'Disk write failed'});await flush()
 assert.ok(player.commands.includes('pause'))
 assert.ok(!view.observed.removed.includes(capture.options.directory))
 view.key('q');await flush();player.finish();await view.done
 assert.equal(view.process.stdin.isRaw,false)
})

test('closing an opening recording cannot open late inputs or lose admitted edits',async()=>{
 let release
 const pending=new Promise(resolve=>{release=resolve})
 const view=await controller({mkdir:()=>pending});await primeWave(view)
 view.command('input interface');view.key('space');await flush()
 const prepare=view.observed.requests.find(job=>job.kind==='prepare-wave')
 view.worker.emit('message',{id:prepare.id,ok:true,result:{path:'/owned/play/plan.json',format:'wave-arrangement'}});await flush()
 view.command('record');await flush();view.key('q');await flush()
 assert.equal(view.observed.captures.length,0);assert.equal(view.observed.terminated,false)
 release();await flush();view.observed.players[0].finish();await view.done
 assert.equal(view.observed.captures.length,0);assert.equal(view.process.stdin.isRaw,false)
})


test('explicit audio monitoring transfers one input owner into recording and back, then drains on exit', async () => {
 const view=await controller(); await primeWave(view)
 view.command('input interface'); view.command('monitor headphones'); await flush()
 const monitor=view.observed.monitors[0]; assert.ok(monitor)
 assert.equal(monitor.options.input,'interface'); assert.equal(monitor.options.monitorOutput,'headphones')
 view.key('space'); await flush()
 const prepare=view.observed.requests.find(job=>job.kind==='prepare-wave')
 view.worker.emit('message',{id:prepare.id,ok:true,result:{path:'/owned/play/plan.json',format:'wave-arrangement'}}); await flush()
 view.command('record'); await flush()
 assert.ok(monitor.stops>0); assert.equal(view.observed.captures.length,0)
 monitor.finish({state:'monitored'}); await flush()
 const captured=view.observed.captures[0]; assert.equal(captured.options.monitorOutput,'headphones')
 assert.equal(view.observed.monitors.length,1)
 view.command('record-stop'); await flush(); assert.ok(captured.stops>0)
 captured.finish({}); await flush()
 const attach=view.observed.requests.find(job=>job.kind==='attach-recording'); assert.ok(attach)
 view.worker.emit('message',{id:attach.id,ok:false,error:'Retained failure'}); await flush()
 const restored=view.observed.monitors[1]; assert.ok(restored)
 let ended=false;view.done.then(()=>{ended=true});view.key('q');await flush()
 assert.ok(restored.stops>0);assert.equal(ended,false)
 restored.finish({state:'monitored'});view.observed.players[0].finish();await view.done
 assert.equal(view.process.stdin.isRaw,false);assert.equal(view.process.stdin.listenerCount('keypress'),0)
})

test('monitor output replacement waits for old close, cancellation opens no later input, and failed routes stay off', async () => {
 const view=await controller()
 view.command('input first');view.command('monitor first-output');await flush()
 const first=view.observed.monitors[0]
 view.command('monitor second-output');await flush();assert.ok(first.stops>0);assert.equal(view.observed.monitors.length,1)
 first.finish({state:'monitored'});await flush()
 const second=view.observed.monitors[1];assert.equal(second.options.monitorOutput,'second-output')
 second.reject(new Error('selected output removed'));await flush()
 view.command('title keep edit');await flush();assert.equal(view.observed.monitors.length,2)
 view.command('monitor third-output');await flush();const third=view.observed.monitors[2];assert.ok(third)
 view.command('input later');await flush();assert.ok(third.stops>0)
 view.key('q');await flush();third.finish({state:'monitored'});await view.done
 assert.equal(view.observed.monitors.length,3);assert.equal(view.process.stdin.isRaw,false)
})


test('live route replacement and exit wait for child closure while preserving independent route selections',async()=>{
 const view=await controller()
 view.command('midi-monitor 10 42 4 6');await flush()
 const first=view.observed.live[0];assert.deepEqual(first.options.routes,[{source:'10',destination:'42',scope:{kind:'channels',channels:[{group:3,channel:5}]}}])
 view.command('midi-monitor 11 43');await flush();assert.ok(first.stops>0);assert.equal(view.observed.live.length,1)
 first.finish({});await flush();const second=view.observed.live[1];assert.equal(second.options.routes.length,2)
 let ended=false;view.done.then(()=>{ended=true});view.key('q');await flush();assert.ok(second.stops>0);assert.equal(ended,false)
 second.finish({});await view.done;assert.equal(view.process.stdin.isRaw,false)
})
test('new backing waits for live close and claims admission; live monitor changes do not finalize recording',async()=>{
 const claims=[{destination:'42',scope:{kind:'channels',channels:[{group:0,channel:0}]}}]
 const view=await controller({backingClaims:claims});await primeWave(view)
 view.command('midi-monitor 10 42 1 2');await flush();const first=view.observed.live[0]
 view.command('input interface');view.key('space');await flush()
 const prepare=view.observed.requests.find(job=>job.kind==='prepare-wave')
 view.worker.emit('message',{id:prepare.id,ok:true,result:{path:'/owned/play/plan.json',format:'wave-arrangement'}});await flush()
 assert.ok(first.stops>0);assert.equal(view.observed.players.length,0)
 first.finish({});await flush();const active=view.observed.live[1]
 assert.deepEqual(active.options.reserved,claims);assert.equal(view.observed.players.length,1)
 view.command('record');await flush();const capture=view.observed.captures[0];assert.ok(capture)
 view.command('midi-monitor off');await flush();assert.equal(capture.stops,0);assert.ok(active.stops>0)
 active.finish({});await flush();view.command('record-stop');await flush();capture.finish({});await flush()
 const attach=view.observed.requests.find(job=>job.kind==='attach-recording');view.worker.emit('message',{id:attach.id,ok:false,error:'retained take'})
 view.key('q');await flush();view.observed.players[0].finish();await view.done
})


test('backing plan survives process closure while its native ownership inspection is admitted',async()=>{
 let release;const inspected=new Promise(resolve=>{release=resolve})
 const view=await controller({inspect:()=>inspected});await primeWave(view);view.key('space');await flush()
 const prepare=view.observed.requests.find(job=>job.kind==='prepare-wave')
 view.worker.emit('message',{id:prepare.id,ok:true,result:{path:'/owned/retained/plan.json',format:'wave-arrangement'}});await flush()
 const player=view.observed.players[0];view.command('midi-monitor 10 42');await flush();assert.equal(view.observed.claims.length,1)
 player.finish();await flush();assert.ok(!view.observed.removed.includes('/owned/retained'));assert.equal(view.observed.live.length,0)
 release();await flush();assert.equal(view.observed.live.length,1);assert.ok(view.observed.removed.includes('/owned/retained'))
 view.key('q');await flush();view.observed.live[0].finish({});await view.done
})

for(const order of ['route-first','backing-first'])for(const conflict of [false,true])test(`concurrent ${order} admission ${conflict?'refuses overlapping':'preserves disjoint'} physical MIDI scopes`,async()=>{
 const claims=[{destination:'42',scope:{kind:'channels',channels:[{group:0,channel:0}]}}]
 const view=await controller({backingClaims:claims,admitLive({routes,reserved}){
  // The native admission seam refuses exactly the physical overlap supplied to it.
  if(reserved.length&&routes.some(route=>route.scope.channels.some(address=>address.channel===0)))throw new Error('Physical channel already reserved')
 }})
 view.command('import-midi /music/take.mid');await flush();const job=view.observed.requests.find(job=>job.kind==='import-midi')
 const asset={id:'asset-1',name:'Keys',kind:'midi',source:importMidiSource(midi())}
 view.worker.emit('message',{id:job.id,ok:true,result:{project:editArrangement(job.project,{kind:'asset-add',asset}),asset:asset.id}});await flush()
 view.command('place asset-1 0');view.command('midi-port asset-1 7 42');view.command('midi-monitor 10 42 1 2');await flush()
 const first=view.observed.live[0];view.key('space');await flush()
 const prepare=view.observed.requests.find(job=>job.kind==='prepare-midi')
 const deliver=()=>view.worker.emit('message',{id:prepare.id,ok:true,result:{path:'/owned/concurrent/plan.json',format:'midi-arrangement',midiOutput:'42',bindings:[{port:0,destination:'42'}]}})
 const replace=()=>view.command(`midi-monitor 10 42 1 ${conflict?1:3}`)
 if(order==='route-first'){replace();await flush();deliver()}else{deliver();await flush();replace()}
 await flush();assert.ok(first.stops>0);assert.equal(view.observed.players.length,0)
 first.finish({});await flush()
 // A queued successor must drain the first admitted replacement before combining scopes.
 const second=view.observed.live[1];assert.ok(second)
 assert.ok(second.stops>0);second.finish({});await flush()
 const combined=view.observed.liveAttempts.at(-1);assert.deepEqual(combined.reserved,claims)
 assert.equal(combined.routes[0].scope.channels[0].channel,conflict?0:2)
 assert.equal(view.observed.claims.at(-1).path,'/owned/concurrent/plan.json')
 // Backing-first may sound with the preceding, disjoint route; the new conflicting
 // live route must still be refused. Route-first must refuse the backing itself.
 assert.equal(view.observed.players.length,conflict&&order==='route-first'?0:1)
 assert.equal(view.observed.live.length,conflict?2:3)
 view.key('q');await flush()
 for(const entry of view.observed.live)entry.finish({})
 for(const player of view.observed.players)player.finish()
 await view.done;assert.equal(view.process.stdin.isRaw,false)
})

test('exit cancels a queued live replacement and prepared backing without reopening a late owner',async()=>{
 const view=await controller();await primeWave(view)
 view.command('midi-monitor 10 42');await flush();const first=view.observed.live[0]
 view.key('space');await flush();const prepare=view.observed.requests.find(job=>job.kind==='prepare-wave')
 view.command('midi-monitor 10 43');await flush()
 view.worker.emit('message',{id:prepare.id,ok:true,result:{path:'/owned/cancelled/plan.json',format:'wave-arrangement'}});await flush()
 view.key('q');await flush();assert.ok(first.stops>0)
 first.finish({});await view.done
 assert.equal(view.observed.live.length,1);assert.equal(view.observed.players.length,0)
 assert.ok(view.observed.removed.includes('/owned/cancelled'));assert.equal(view.process.stdin.isRaw,false)
})

test('calibration cancellation retains the arrangement and admits queued edits only after owned cleanup',async()=>{
 for(const key of ['q','escape']){
 const view=await controller();view.command('input selected-interface');view.command('calibrate selected-output 2 1 250');await flush()
 const pending=view.observed.calibrations[0];assert.ok(pending);const job=pending.options
 assert.equal(job.input,'selected-interface');assert.equal(job.output,'selected-output');assert.equal(job.inputChannel,2);assert.equal(job.outputChannel,1);assert.equal(job.maxLagMs,250)
 let ended=false;view.done.then(()=>{ended=true});view.key(key);view.key(key);await flush()
 assert.equal(ended,false);assert.equal(job.signal.aborted,true)
 assert.equal(view.process.stdin.listenerCount('keypress'),1);assert.equal(view.observed.terminated,false)
 view.key(undefined,':');for(const char of 'title A quiet take')view.key(char,char);view.key('return')
 view.command('save');await flush();assert.equal(view.observed.saved.length,0)
 pending.reject(new Error('Evidence retained after cancellation'))
 await flush();assert.equal(ended,false);assert.equal(view.observed.saved.at(-1).project.title,'A quiet take')
 view.key('q')
 await view.done;assert.equal(view.observed.live.length,0);assert.equal(view.observed.players.length,0);assert.equal(view.process.stdin.isRaw,false)
 }
})
test('cancelled calibration drains audio and MIDI owners before restoring each route once',async()=>{
 const view=await controller();view.command('input interface');view.command('monitor headphones');view.command('midi-monitor 10 42');await flush()
 const monitor=view.observed.monitors[0],live=view.observed.live[0]
 view.command('calibrate output 1 1 50');await flush();assert.ok(monitor.stops>0)
 view.key('escape');view.key('q');monitor.finish({});await flush();assert.ok(live.stops>0)
 assert.equal(view.observed.monitors.length,1);assert.equal(view.observed.live.length,1)
 live.finish({});await flush()
 assert.equal(view.observed.calibrations.length,0);assert.equal(view.observed.monitors.length,2);assert.equal(view.observed.live.length,2)
 view.command('title Still editing');view.command('save');await flush();assert.equal(view.observed.saved.at(-1).project.title,'Still editing')
 view.key('q');await flush();view.observed.monitors[1].finish({});view.observed.live[1].finish({});await view.done
})
test('calibration cancel targets its analysis request and waits for worker settlement before restoring monitoring',async()=>{
 const view=await controller();view.command('input interface');view.command('monitor headphones');await flush()
 view.command('calibrate output 1 1 50');await flush();view.observed.monitors[0].finish({});await flush()
 const pending=view.observed.calibrations[0]
 const analysis=pending.options.analyze({signal:pending.options.signal,directory:pending.options.directory})
 const settled=analysis.then(pending.finish,pending.reject)
 const request=view.observed.requests.find(job=>job.kind==='analyze-calibration')
 view.key('q');view.key('escape');await flush()
 assert.deepEqual(view.observed.requests.filter(job=>job.kind==='cancel'),[{kind:'cancel',request:request.id}])
 assert.equal(view.observed.monitors.length,1);assert.equal(view.observed.terminated,false)
 view.worker.emit('message',{id:request.id,ok:false,cancelled:true,error:'Analysis cancelled'})
 await settled;await flush();assert.equal(view.observed.monitors.length,2)
 view.key('q');await flush();view.observed.monitors[1].finish({});await view.done
})
test('Ctrl-C exits during calibration and never opens a monitoring successor',async()=>{
 const view=await controller();view.command('input interface');view.command('monitor headphones');await flush()
 view.command('calibrate output 1 1 50');await flush();view.observed.monitors[0].finish({});await flush()
 const pending=view.observed.calibrations[0];view.key('c','',{ctrl:true});await flush()
 assert.equal(pending.options.signal.aborted,true)
 pending.reject(new Error('Native children drained'));await view.done
 assert.equal(view.observed.monitors.length,1);assert.equal(view.observed.terminated,true)
})
test('calibration refuses active backing, drains a live owner and keeps the project unchanged',async()=>{
 const view=await controller();await primeWave(view);view.command('input interface');view.key('space');await flush()
 view.command('calibrate output 1 1 50');await flush();assert.equal(view.observed.calibrations.length,0)
 const prepare=view.observed.requests.find(job=>job.kind==='prepare-wave');view.worker.emit('message',{id:prepare.id,ok:true,result:{path:'/owned/calibration/plan.json',format:'wave-arrangement'}});await flush()
 view.observed.players[0].finish();await flush()
 view.command('midi-monitor 10 42');await flush();const live=view.observed.live[0]
 view.command('calibrate output 1 1 50');await flush();assert.ok(live.stops>0)
 live.finish({});await flush();const pending=view.observed.calibrations[0];assert.ok(pending)
 pending.finish({directory:pending.options.directory,matches:[{residualMs:1,correlation:.9},{residualMs:1.01,correlation:.89}]});await flush()
 assert.equal(view.observed.live.length,2);assert.equal(view.observed.players.length,1)
 view.key('q');await flush();view.observed.live[1].finish({});await view.done
 assert.equal(view.observed.saved.at(-1).project.assets.length,1);assert.equal(view.observed.saved.at(-1).project.clips.length,1)
})

test('worker failure aborts the parent-owned calibration before any monitoring successor can open',async()=>{
 const view=await controller();view.command('input interface');view.command('monitor headphones');await flush()
 const first=view.observed.monitors[0];view.command('calibrate output 1 1 50');await flush();assert.ok(first.stops>0)
 first.finish({});await flush();const pending=view.observed.calibrations[0];assert.ok(pending)
 view.worker.emit('error',new Error('Analysis worker failed'));await flush()
 assert.equal(pending.options.signal.aborted,true);assert.equal(view.observed.monitors.length,1)
 pending.reject(new Error('Native children drained'));await flush();assert.equal(view.observed.monitors.length,2)
 view.key('q');await flush();view.observed.monitors[1].finish({});await view.done
})

test('a failed analysis worker cannot admit calibration before or after draining an old live owner',async()=>{
 for(const duringDrain of [false,true]){
  const view=await controller();view.command('input interface');await flush()
  if(duringDrain){
   view.command('midi-monitor 10 42');await flush();view.command('calibrate output 1 1 50');await flush()
   assert.ok(view.observed.live[0].stops>0)
  }
  view.worker.emit('exit',1);await flush()
  if(duringDrain)view.observed.live[0].finish({})
  else view.command('calibrate output 1 1 50')
  await flush();assert.equal(view.observed.calibrations.length,0)
  view.key('q');await flush();for(const live of view.observed.live)live.finish({})
  await view.done;assert.equal(view.process.stdin.isRaw,false)
 }
})

test('selected next-take correction is frozen before opening input, retained for failed attachment and restored with undo',async()=>{
 const view=await controller();await primeWave(view)
 view.command('input interface');view.command('mixed-output output');view.command('record-correction manual 12.5 1 2');await flush()
 view.command('play');await flush();const prepare=view.observed.requests.find(j=>j.kind==='prepare-wave')
 view.worker.emit('message',{id:prepare.id,ok:true,result:{path:'/owned/play/plan.json',format:'wave-arrangement'}});await flush()
 view.command('record');await flush();const capture=view.observed.captures[0];assert.ok(capture)
 const intent=view.observed.writes.find(w=>w.path===capture.options.directory+'.request.json')
 assert.ok(intent);assert.equal(JSON.parse(intent.data).correction.placement.advanceNanoseconds.numerator,'12500000')
 view.command('record-correction none');await flush();assert.ok(capture.stops>0)
 capture.finish({});await flush();const job=view.observed.requests.find(j=>j.kind==='attach-recording')
 assert.equal(job.correction.kind,'audio');assert.equal(job.correction.input,'interface');assert.deepEqual(job.correction.audioChannel,{input:1,output:2})
 view.worker.emit('message',{id:job.id,ok:false,error:'Preserved failed attachment'});await flush()
 view.command('undo');await flush();view.key('q');await flush();view.observed.players[0].finish();await view.done
 const saved=view.observed.saved.at(-1).project;assert.equal(saved.recordingCorrection.kind,'audio')
 assert.deepEqual(JSON.parse(intent.data).correction,saved.recordingCorrection)
 assert.ok(!view.observed.removed.includes(capture.options.directory));assert.equal(view.process.stdin.isRaw,false)
})
test('stale recording input selection refuses correction before opening a recorder',async()=>{
 const view=await controller();await primeWave(view)
 view.command('input interface');view.command('mixed-output output');view.command('record-correction manual 3 1 1');view.command('input changed');await flush()
 view.command('play');await flush();const prepare=view.observed.requests.find(j=>j.kind==='prepare-wave')
 view.worker.emit('message',{id:prepare.id,ok:true,result:{path:'/owned/play/plan.json',format:'wave-arrangement'}});await flush()
 view.command('record');await flush();assert.equal(view.observed.captures.length,0)
 view.key('q');await flush();view.observed.players[0].finish();await view.done;assert.equal(view.process.stdin.isRaw,false)
})


test('record from stopped practice waits for admitted backing and captures against its fresh epoch',async()=>{
 const view=await controller();await primeWave(view)
 try {
  view.command('practice 1 on');view.command('input interface');view.command('record');await flush()
  const prepare=view.observed.requests.find(job=>job.kind==='prepare-wave')
  assert.ok(prepare);assert.deepEqual(prepare.project.practice,{countInBars:1,metronome:true});assert.equal(view.observed.captures.length,0)
  view.worker.emit('message',{id:prepare.id,ok:true,result:{path:'/owned/practice/plan.json',format:'wave-arrangement'}});await flush();await flush()
  assert.equal(view.observed.players.length,1);assert.equal(view.observed.captures.length,1)
  const capture=view.observed.captures[0]
  assert.equal(capture.options.input,'interface')
  const intent=JSON.parse(view.observed.writes.find(item=>item.path.endsWith('.request.json')).data)
  assert.equal(intent.epoch.clock.anchor,'9007199254740993123')
  view.command('record-stop');await flush();capture.finish({});await flush()
  const attach=view.observed.requests.find(job=>job.kind==='attach-recording');assert.deepEqual(attach.epoch,intent.epoch)
  view.worker.emit('message',{id:attach.id,ok:false,error:'retain complete take'});await flush()
 }finally{await closeController(view)}
})

test('closing a record-triggered preparation rejects late playback and late input admission',async()=>{
 const view=await controller();await primeWave(view)
 view.command('practice 1 off');view.command('input interface');view.command('record');await flush()
 const prepare=view.observed.requests.find(job=>job.kind==='prepare-wave');assert.ok(prepare)
 view.key('q');await flush()
 view.worker.emit('message',{id:prepare.id,ok:true,result:{path:'/owned/practice/late/plan.json',format:'wave-arrangement'}})
 await view.done
 assert.equal(view.observed.players.length,0);assert.equal(view.observed.captures.length,0)
 assert.ok(view.observed.removed.includes('/owned/practice/late'));assert.equal(view.process.stdin.isRaw,false)
})


test('stop cancels a record-triggered preparation without waiting for the worker and cannot open late inputs',async()=>{
 const view=await controller();await primeWave(view)
 try {
  view.command('practice 1 on');view.command('input interface');view.command('record');await flush()
  const prepare=view.observed.requests.find(job=>job.kind==='prepare-wave');assert.ok(prepare)
  view.command('stop');await flush()
  assert.ok(view.observed.requests.some(job=>job.kind==='cancel'&&job.request===prepare.id))
  view.worker.emit('message',{id:prepare.id,ok:true,result:{path:'/owned/practice/stopped/plan.json',format:'wave-arrangement'}});await flush()
  assert.equal(view.observed.players.length,0);assert.equal(view.observed.captures.length,0)
  assert.ok(view.observed.removed.includes('/owned/practice/stopped'))
 }finally{await closeController(view)}
})

test('a rejected playing acknowledgement stops its child and retains private sources until child closure',async()=>{
 let rejectReady;const playbackReady=new Promise((yes,no)=>{rejectReady=no})
 playbackReady.catch(()=>{})
 const view=await controller({playbackReady});await primeWave(view)
 try {
  view.key('space');await flush();const prepare=view.observed.requests.find(job=>job.kind==='prepare-wave')
  view.worker.emit('message',{id:prepare.id,ok:true,result:{path:'/owned/practice/rejected/plan.json',format:'wave-arrangement'}});await flush()
  rejectReady(new Error('native acknowledgement failed'));await flush()
  assert.ok(view.observed.players[0].commands.includes('stop'))
  assert.ok(!view.observed.removed.includes('/owned/practice/rejected'))
  view.observed.players[0].finish();await flush()
  assert.ok(view.observed.removed.includes('/owned/practice/rejected'))
 }finally{await closeController(view)}
})


test('arrangement phrase edit imports one immutable variant after child closure and undo restores the previous document',async()=>{
 const view=await controller();await primeWave(view)
 try {
  view.command('phrase');await flush();const prep=view.observed.requests.find(job=>job.kind==='prepare-phrase')
  assert.equal(prep.asset,undefined);assert.equal(view.observed.phrases.length,0)
  const phrase=newProject();view.worker.emit('message',{id:prep.id,ok:true,result:phrase});await flush()
  const child=view.observed.phrases[0];assert.ok(child.options.embedded);assert.equal(view.process.stdin.listenerCount('keypress'),0)
  const edited=editProject(phrase,'track-1',{kind:'chord',symbol:'Cmaj7',start:0,duration:PPQ,mode:'drop2',octave:4,velocity:96})
  child.finish({project:edited,changed:true});await flush()
  const job=view.observed.requests.find(job=>job.kind==='import-phrase');assert.ok(job)
  assert.deepEqual(job.document,edited)
  view.worker.emit('message',{id:job.id,ok:true,result:importPhraseDocument(job.project,job.document)});await flush()
  view.command('save');await flush();const changed=view.observed.saved.at(-1).project
  assert.equal(changed.assets.length,2);assert.deepEqual(changed.clips,prep.project.clips)
  assert.deepEqual(changed.assets[1].phrase,edited);assert.equal(view.process.stdin.listenerCount('keypress'),1)
  view.command('undo');view.command('save');await flush()
  assert.deepEqual(view.observed.saved.at(-1).project,prep.project)
 }finally{await closeController(view)}
})

test('closing an active MIDI edit waits for child cancellation and refuses its late variant import',async()=>{
 const view=await controller();await primeWave(view)
 view.command('phrase');await flush();const prep=view.observed.requests.find(job=>job.kind==='prepare-phrase')
 view.worker.emit('message',{id:prep.id,ok:true,result:newProject()});await flush()
 const child=view.observed.phrases[0];view.abort.abort();await flush()
 assert.equal(child.options.signal.aborted,true);assert.equal(view.observed.terminated,false)
 child.finish({project:newProject(),changed:true});await view.done
 assert.equal(view.observed.requests.some(job=>job.kind==='import-phrase'),false)
 assert.equal(view.process.stdin.isRaw,false)
})

test('returning from SMF2 editing carries the edited pattern into Enter placement without changing other patterns',async()=>{
 const track=pitch=>Buffer.from([0,0xb0,1,77,0,0x90,pitch,100,0x83,0x60,0x80,pitch,45,0,0xff,0x2f,0])
 const chunk=bytes=>{const header=Buffer.alloc(8);header.write('MTrk');header.writeUInt32BE(bytes.length,4);return Buffer.concat([header,bytes])}
 const bytes=Buffer.concat([Buffer.from('4d546864000000060002000201e0','hex'),chunk(track(60)),chunk(track(67))])
 const source=importMidiSource(bytes),view=await controller()
 try {
  view.command('import-midi /music/patterns.mid');await flush()
  const job=view.observed.requests.find(job=>job.kind==='import-midi')
  const asset={id:'asset-1',kind:'midi',name:'Patterns',source}
  view.worker.emit('message',{id:job.id,ok:true,result:{project:editArrangement(job.project,{kind:'asset-add',asset}),asset:asset.id}});await flush()
  view.command('place asset-1 0 2');view.command('edit-midi');await flush()
  const prep=view.observed.requests.find(job=>job.kind==='prepare-phrase')
  view.worker.emit('message',{id:prep.id,ok:true,result:source});await flush()
  const child=view.observed.phrases[0];assert.equal(child.options.pattern,1)
  const edited=editorCommand(newEditor(source,{pattern:child.options.pattern}),'transpose 2').editor
  child.finish({project:edited.project,pattern:edited.pattern,changed:true});await flush()
  const imported=view.observed.requests.find(job=>job.kind==='import-phrase')
  view.worker.emit('message',{id:imported.id,ok:true,result:importPhraseDocument(imported.project,imported.document)});await flush()
  view.command('cursor 2');view.key('return');view.command('save');await flush()
  const saved=view.observed.saved.at(-1).project
  assert.equal(saved.clips.length,2);assert.equal(saved.clips[1].asset,'asset-2');assert.equal(saved.clips[1].pattern,1)
  assert.equal(saved.clips[1].position,2*PPQ)
  assert.deepEqual(Buffer.from(exportMidiSource(saved.assets[0].source)),bytes)
  assert.deepEqual(midiSourcePattern(saved.assets[1].source,{pattern:0}),midiSourcePattern(source,{pattern:0}))
  assert.equal(midiSourcePattern(saved.assets[1].source,{pattern:1}).notes[0].pitch,69)
  // Selecting another source clears the child selection instead of inventing an SMF2 default.
  let state=editorAPI.arrangementImported(editorAPI.arrangementEditor(),{project:saved,asset:'asset-2',pattern:1})
  state=editorAPI.arrangementCommand(state,'asset asset-1').editor
  assert.throws(()=>editorAPI.arrangementAction(state,{kind:'place'}),/format-2 MIDI pattern/)
  state=editorAPI.arrangementCommand(state,'select '+saved.clips[0].id).editor
  assert.equal(editorAPI.arrangementAction(state,{kind:'place'}).project.clips.at(-1).pattern,1)
 }finally{await closeController(view)}
})

test('stop fences a late phrase preparation before child keyboard or input ownership transfers',async()=>{
 const view=await controller();await primeWave(view)
 try {
  view.command('phrase');await flush();const prep=view.observed.requests.find(job=>job.kind==='prepare-phrase')
  view.command('stop');await flush();assert.ok(view.observed.requests.some(job=>job.kind==='cancel'&&job.request===prep.id))
  view.worker.emit('message',{id:prep.id,ok:true,result:newProject()});await flush()
  assert.equal(view.observed.phrases.length,0);assert.equal(view.process.stdin.listenerCount('keypress'),1)
 }finally{await closeController(view)}
})
