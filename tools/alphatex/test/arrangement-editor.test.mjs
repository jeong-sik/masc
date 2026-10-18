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
import { importMidiSource, exportMidiSource } from '../midi-source.mjs'

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
  const observed={requests:[],saved:[],recovered:[],terminated:false,players:[],removed:[],takes:[]},process=new EventEmitter()
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
    emitKeypressEvents(){},safeText:String,
    viewSession(options){
      let finish
      const completion=new Promise(resolve=>{finish=resolve})
      observed.takes.push({options,finish});return completion
    },
    verifyArrangementAssets:async()=>new Map(),
    loadArrangement:async()=>{throw new Error('Unexpected load')},
    mkdtemp:async()=>'/owned-recovery',writeFile:async()=>{},rm:async path=>{observed.removed.push(path)},openPlayback(options){
      let resolve,reject
      const completion=new Promise((yes,no)=>{resolve=yes;reject=no})
      const event=(kind,currentTime=0)=>options.onEvent({kind,currentTime,duration:10,device:{id:'output',name:'Output',outputs:2},loop:false})
      const handle={completion,ready:Promise.resolve(),stop(){entry.commands.push('stop')},terminate(){entry.commands.push('terminate')},pause(){entry.commands.push('pause');event('paused')},resume(){entry.commands.push('resume');event('playing')},status(){entry.commands.push('status')},seek(seconds){entry.commands.push(['seek',seconds])}}
      const entry={options,handle,commands:[],finish(){event('stopped');resolve({kind:'stopped'})},reject,event}
      observed.players.push(entry);queueMicrotask(()=>event('playing'));return handle
    },
    saveProject:async()=>{throw new Error('Unexpected unverified recovery')},
    saveArrangement:async(path,project,revision,extra)=>{observed.recovered.push({path,project,revision,...extra})},
  }
  const source=(await readFile(new URL('../arrangement-tui.mjs',import.meta.url),'utf8')).replace(/^import .*$/gm,'')
    .replace("new URL('./arrangement-worker.mjs', import.meta.url)","new URL('file:///worker')")
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
  for (const job of view.observed.requests.filter(job=>['prepare-wave','prepare-midi','prepare-mixed','prepare-take','import-wave','import-midi','import-take'].includes(job.kind))) {
    view.worker.emit('message',{id:job.id,ok:false,cancelled:true,error:'Cancelled'})
  }
  for (const player of view.observed.players) player.finish()
  for (const take of view.observed.takes) take.finish()
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
test('captured-region commands persist typed bounds and refuse playback until the lane is muted',async()=>{
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
