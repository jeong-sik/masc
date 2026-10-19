import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { tmpdir } from 'node:os'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { newArrangement, editArrangement } from '../arrangement.mjs'
import { arrangementEditor, arrangementCommand } from '../arrangement-editor.mjs'
import { loadArrangement } from '../arrangement-files.mjs'
import { practiceClock } from '../arrangement-practice.mjs'
import { arrangementPlaybackRequest, arrangementRoute } from '../arrangement-playback.mjs'

function wave() {
  const b=Buffer.alloc(44+48000*2);b.write('RIFF');b.writeUInt32LE(b.length-8,4);b.write('WAVEfmt ',8)
  b.writeUInt32LE(16,16);b.writeUInt16LE(1,20);b.writeUInt16LE(1,22);b.writeUInt32LE(48000,24);b.writeUInt32LE(96000,28)
  b.writeUInt16LE(2,32);b.writeUInt16LE(16,34);b.write('data',36);b.writeUInt32LE(b.length-44,40);return b
}
const midi=Buffer.from('4d546864000000060000000101e04d54726b0000000d00903c648360803c0000ff2f00','hex')

test('practice is immutable, undoable and validated before editing a saved session',()=>{
  let e=arrangementEditor(), before=e.project
  e=arrangementCommand(e,'practice 2 on').editor
  assert.deepEqual(e.project.practice,{countInBars:2,metronome:true});assert.equal(before.practice,undefined)
  assert.equal(arrangementCommand(e,'undo').editor.project,before)
  for(const line of ['practice -1 on','practice 1.5 off','practice 1 maybe','practice 9007199254740992 off'])assert.throws(()=>arrangementCommand(e,line))
  const project={...e.project,tempo:137,meter:[7,8]}
  assert.deepEqual(practiceClock(project),{period:{numerator:'30000000000',denominator:'137'},beatsPerBar:7,countInSeconds:420/137})
  assert.throws(()=>editArrangement(e.project,{kind:'practice',practice:{countInBars:1,metronome:true,unknown:true}}))
})

test('actual preparation worker preserves original MIDI/audio, shifts backing once and saves practice across reopen',async()=>{
  const directory=await mkdtemp(join(tmpdir(),'masc-practice-')),worker=new Worker(new URL('../arrangement-worker.mjs',import.meta.url))
  let id=0
  const request=async job=>{const reply=once(worker,'message');worker.postMessage({...job,id:++id});const [result]=await reply;assert.equal(result.ok,true,result.error);return result.result}
  try {
    const path=join(directory,'song.json'), input=join(directory,'in.wav'), mid=join(directory,'in.mid'), bytes=wave()
    await writeFile(input,bytes);await writeFile(mid,midi)
    let result=await request({kind:'import-wave',project:newArrangement({tempo:120}),path:input,projectPath:path})
    let project=editArrangement(result.project,{kind:'lane-add',sourceKind:'wave',name:'Audio'})
    project=editArrangement(project,{kind:'region-add',lane:project.lanes[0].id,asset:result.asset,position:0,offset:0,extent:48000,repeat:1,name:'Backing'})
    project=editArrangement(project,{kind:'practice',practice:{countInBars:2,metronome:true}})
    const wavePrepared=await request({kind:'prepare-wave',project,sourceRoot:directory,directory})
    const plan=JSON.parse(await readFile(wavePrepared.path,'utf8'))
    assert.equal(plan.practice.countInSeconds,4);assert.equal(plan.practice.duration,1);assert.equal(plan.duration,5)
    assert.equal(plan.regions[0].startSeconds,4);assert.equal(plan.regions[1].pulseClock.duration,5)
    assert.deepEqual(await readFile(plan.assets[0].path),bytes)
    project=editArrangement(project,{kind:'practice',practice:{countInBars:1,metronome:false}})
    const onlyCount=JSON.parse(await readFile((await request({kind:'prepare-wave',project,sourceRoot:directory,directory})).path,'utf8'))
    assert.equal(onlyCount.duration,3);assert.equal(onlyCount.regions[1].pulseClock.duration,2)
    const empty=editArrangement(newArrangement({tempo:120}),{kind:'practice',practice:{countInBars:1,metronome:true}})
    result=await request({kind:'import-midi',project:empty,path:mid})
    let notes=editArrangement(result.project,{kind:'lane-add',sourceKind:'midi',name:'Keys'})
    notes=editArrangement(notes,{kind:'region-add',lane:notes.lanes[0].id,asset:result.asset,position:0,offset:0,extent:480,repeat:1,name:'Notes'})
    assert.throws(()=>arrangementPlaybackRequest(notes,arrangementRoute({midiOutput:'123'})))
    const selection=arrangementPlaybackRequest(notes,arrangementRoute({output:'audio',midiOutput:'123'}))
    assert.equal(selection.output,'audio')
    const plain={...notes,practice:{countInBars:0,metronome:false}}
    const before=JSON.parse(await readFile((await request({...selection,project:plain,directory})).path,'utf8'))
    const prepared=await request({...selection,project:notes,directory}), combined=JSON.parse(await readFile(prepared.path,'utf8'))
    assert.equal(prepared.format,'mixed-arrangement');assert.equal(combined.schemaVersion,2)
    assert.deepEqual(combined.midi.sources,before.sources);assert.deepEqual(combined.midi.bindings,before.bindings)
    assert.equal(combined.midi.regions[0].startSeconds,2);assert.equal(combined.midi.duration,before.duration+2)
    await request({kind:'save',project:notes,path,revision:null,sourceRoot:directory})
    assert.deepEqual((await loadArrangement(path)).project,notes)
    assert.deepEqual(await readFile(mid),midi)
    // An aborted preparation cannot leak private click/source files.
    const abort=new AbortController();abort.abort()
    const {preparePractice}=await import('../arrangement-practice.mjs')
    await assert.rejects(preparePractice(notes,prepared,{signal:abort.signal}))
    await assert.rejects(readFile(join(dirname(prepared.path),'plan.json')))
  } finally {await worker.terminate();await rm(directory,{recursive:true,force:true})}
})


test('practice shifts exact captured placement and its display together without rewriting source clocks',async()=>{
 const directory=await mkdtemp(join(tmpdir(),'masc-practice-exact-'))
 try {
  const path=join(directory,'plan.json'), exact={numerator:'1',denominator:'3'}
  const source={clock:{origin:'9007199254740993123',numer:125,denom:3},packets:[{hostTime:'9007199254740993124',words:[0x40903c00,0x90000000]}]}
  const notes={id:'paired',source:'take',startSeconds:1/3e9,startNanoseconds:exact,offset:'0',extent:'1000000',repeatCount:1}
  await writeFile(path,JSON.stringify({schemaVersion:5,kind:'capture-arrangement',duration:1,assets:[],regions:[{id:'paired',startSeconds:notes.startSeconds}],umpRegions:{duration:1,sources:[source],regions:[notes]}}))
  const {preparePractice}=await import('../arrangement-practice.mjs')
  const project={...newArrangement({tempo:137}),meter:[7,8],practice:{countInBars:2,metronome:true}}
  await preparePractice(project,{path,duration:1,format:'capture-arrangement'})
  const plan=JSON.parse(await readFile(path,'utf8')), shifted=plan.umpRegions.regions[0], fraction=shifted.startNanoseconds
  assert.equal(BigInt(fraction.numerator)*411n,(1n*137n+420_000_000_000n*3n)*BigInt(fraction.denominator))
  assert.equal(plan.regions[0].startSeconds,shifted.startSeconds)
  const n=BigInt(fraction.numerator),d=BigInt(fraction.denominator)*1_000_000_000n
  assert.equal(shifted.startSeconds,Number(n/d)+Number(n%d)/Number(d))
  assert.deepEqual(plan.umpRegions.sources,[source]);assert.equal(notes.startNanoseconds,exact)
 }finally{await rm(directory,{recursive:true,force:true})}
})
