import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { importMidiSource, midiSourcePattern } from '../midi-source.mjs'
import { newArrangement, editArrangement, sourceNanosecondsAtTick } from '../arrangement.mjs'
import { prepareArrangementMidi } from '../arrangement-playback.mjs'
import { arrangementEditor, arrangementCommand } from '../arrangement-editor.mjs'
import { regionEdgeSeconds, fraction } from '../exact-time.mjs'
const chunk = (type, bytes) => { const h = Buffer.alloc(8); h.write(type); h.writeUInt32BE(bytes.length, 4); return Buffer.concat([h, Buffer.from(bytes)]) }
const source = (division = 480, format = 1) => {
  const h = Buffer.alloc(6); h.writeUInt16BE(format); h.writeUInt16BE(2, 2); h.writeUInt16BE(division, 4)
  return importMidiSource(Buffer.concat([chunk('MThd', h), chunk('MTrk', [0,255,81,3,7,161,32,0x83,0x60,255,81,3,15,66,64,0x83,0x60,255,47,0]),
    chunk('MTrk', [0,255,33,1,7,0,0xc0,33,0,0xb0,64,0,0,0x90,60,100,0x83,0x60,0x80,60,77,0x83,0x60,255,47,0])]))
}
function project(doc = source(), pattern) {
  let p = editArrangement(newArrangement({tempo:120}),{kind:'asset-add',asset:{id:'a',kind:'midi',name:'Expressive',source:doc}})
  p=editArrangement(p,{kind:'lane-add',sourceKind:'midi',name:'Keys'})
  return editArrangement(p,{kind:'region-add',name:'Cut',asset:'a',lane:'lane-1',position:960,offset:240,extent:720,repeat:2_000_000,...(pattern===undefined?{}:{pattern})})
}
async function workspace(run) { const directory=await mkdtemp(join(tmpdir(),'masc-midi-regions-'));try {await run(directory)}finally{await rm(directory,{recursive:true,force:true})} }
test('MIDI region plans retain expression and original tempo while keeping millions of repetitions compressed',async()=>workspace(async directory=>{
  const p=project(),before=structuredClone(p)
  const result=await prepareArrangementMidi(p,{directory,portBindings:[{asset:'a',port:7,destination:'42'}]})
  const plan=JSON.parse(await readFile(result.path))
  assert.equal(result.format,'midi-arrangement');assert.deepEqual(result.bindings,[{port:0,destination:'42'}])
  assert.deepEqual(plan.regions,[{id:'region-1',source:'["a",null]',startSeconds:.5,sourceStart:.25,sourceEnd:1.5,repeatCount:2_000_000,
    startNanoseconds:{numerator:'500000000',denominator:'1'},periodNanoseconds:{numerator:'1250000000',denominator:'1'}}])
  assert.deepEqual(plan.sources[0].timeline.events.map(e=>e.bytes),[[192,33],[176,64,0],[144,60,100],[128,60,77]])
  assert.equal(plan.duration,2_500_000.5);assert.deepEqual(p,before)
  const repeated=editArrangement(p,{kind:'region-duplicate',id:'region-1',position:1920})
  const again=JSON.parse(await readFile((await prepareArrangementMidi(repeated,{directory,midiOutput:'42'})).path))
  assert.equal(again.sources.length,1);assert.equal(again.regions.length,2)
}))
test('SMPTE region time remains independent of project tempo and format2 chooses its source pattern explicitly',async()=>workspace(async directory=>{
  const p=project(source(0xe350));const r=await prepareArrangementMidi(p,{directory,midiOutput:'42'});const plan=JSON.parse(await readFile(r.path))
  assert.equal(plan.regions[0].sourceStart,.1001);assert.equal(plan.regions[0].sourceEnd,.4004)
  assert.throws(()=>project(source(480,2)),/pattern explicitly/)
  const chosen=await prepareArrangementMidi(project(source(480,2),1),{directory,midiOutput:'42'})
  assert.equal(JSON.parse(await readFile(chosen.path)).sources[0].id,'["a",1]')
}))
test('invalid or missing source routes and preparation cancellation create no native plans',async()=>workspace(async directory=>{
  const p=project();await assert.rejects(prepareArrangementMidi(p,{directory}),/output for every/)
  await assert.rejects(prepareArrangementMidi(p,{directory,midiOutput:'01'}),/exact signed/)
  const controller=new AbortController();controller.abort()
  await assert.rejects(prepareArrangementMidi(p,{directory,midiOutput:'42',signal:controller.signal}),{name:'AbortError'})
  assert.deepEqual(await readdir(directory),[])
  const effect=arrangementCommand(arrangementEditor(p),'midi-port a 7 -42').effect
  assert.deepEqual(effect,{kind:'midi-port',asset:'a',port:7,destination:'-42'})
  assert.throws(()=>arrangementCommand(arrangementEditor(p),'midi-port a 128 -42'))
}))
// 100 BPM SMF, one sixteenth note per 120 ticks: the binary64 source keys of
// ticks 1920..3840 are 2.3999999999999995..4.800000000000001, but the region and
// its duplicate at beat 4 meet exactly at 2.4e9 ns.
function sixteenths() {
  const h = Buffer.alloc(6); h.writeUInt16BE(0); h.writeUInt16BE(1, 2); h.writeUInt16BE(480, 4)
  const track = [0, 255, 81, 3, 0x09, 0x27, 0xc0]
  for (let i = 0; i < 64; i++) track.push(0, 0x90, 60, 100, 120, 0x80, 60, 0)
  let p = editArrangement(newArrangement({ tempo: 100 }), { kind: 'asset-add', asset: { id: 'a', kind: 'midi', name: 'Sixteenths',
    source: importMidiSource(Buffer.concat([chunk('MThd', h), chunk('MTrk', [...track, 0, 255, 47, 0])])) } })
  p = editArrangement(p, { kind: 'lane-add', sourceKind: 'midi', name: 'Keys' })
  p = editArrangement(p, { kind: 'region-add', name: 'A', asset: 'a', lane: 'lane-1', position: 0, offset: 1920, extent: 1920 })
  return editArrangement(p, { kind: 'region-duplicate', id: 'region-1', position: 4 * p.ppq })
}
const edge = (region, copy) => regionEdgeSeconds(region.startNanoseconds, region.periodNanoseconds, copy)
test('adjacent MIDI regions share one exact native edge while source keys keep their binary64 tempo-map values',async()=>workspace(async directory=>{
  const plan=JSON.parse(await readFile((await prepareArrangementMidi(sixteenths(),{directory,midiOutput:'42'})).path))
  assert.deepEqual(plan.regions.map(r=>[r.startSeconds,r.sourceStart,r.sourceEnd,r.startNanoseconds,r.periodNanoseconds]),[
    [0,2.3999999999999995,4.800000000000001,{numerator:'0',denominator:'1'},{numerator:'2400000000',denominator:'1'}],
    [2.4,2.3999999999999995,4.800000000000001,{numerator:'2400000000',denominator:'1'},{numerator:'2400000000',denominator:'1'}]])
  assert.equal(edge(plan.regions[0],1),2.4);assert.equal(edge(plan.regions[1],0),2.4);assert.equal(plan.duration,4.8)
}))
test('loop pieces of adjacent MIDI regions abut on their exact edges',async()=>workspace(async directory=>{
  const looped=editArrangement(sixteenths(),{kind:'loop',range:{start:960,end:6*960}})
  const prepared=await prepareArrangementMidi(looped,{directory,midiOutput:'42'}),plan=JSON.parse(await readFile(prepared.path))
  assert.deepEqual(plan.regions.map(r=>[r.id,r.repeatCount,r.startNanoseconds,r.periodNanoseconds]),[
    ['["region-1","leading"]',1,{numerator:'0',denominator:'1'},{numerator:'1800000000',denominator:'1'}],
    ['["region-2","trailing"]',1,{numerator:'1800000000',denominator:'1'},{numerator:'1200000000',denominator:'1'}]])
  assert.equal(edge(plan.regions[0],1),edge(plan.regions[1],0));assert.equal(edge(plan.regions[1],1),3)
  assert.equal(plan.duration,3);assert.equal(prepared.originSeconds,.6)
}))
// Expected values are hand-computed from the bytes: ticks * microseconds per
// quarter / PPQ per tempo segment, or ticks / ticksPerFrame * 1001 / 30000
// seconds at 29.97 fps SMPTE.
test('exact source nanoseconds follow every tempo change of a merged SMF and ignore tempo under SMPTE',()=>{
  const pattern=(division,tracks)=>{
    const h=Buffer.alloc(6);h.writeUInt16BE(1);h.writeUInt16BE(tracks.length,2);h.writeUInt16BE(division,4)
    return midiSourcePattern(importMidiSource(Buffer.concat([chunk('MThd',h),...tracks.map(track=>chunk('MTrk',track))])))
  }
  const at=(performance,tick)=>fraction(...sourceNanosecondsAtTick(performance,tick))
  // 500000 us per quarter from tick 0 and 333333 from tick 1440 in the first
  // track; 400000 from tick 960 in the note track, between the two.
  const tempo=pattern(480,[[0,255,81,3,0x07,0xa1,0x20,0x8b,0x20,255,81,3,0x05,0x16,0x15,0,255,47,0],
    [0,0x90,60,100,0x87,0x40,255,81,3,0x06,0x1a,0x80,0x87,0x40,0x80,60,0,0,255,47,0]])
  for(const [tick,numerator,denominator] of [[0,'0','1'],[480,'500000000','1'],[960,'1000000000','1'],[1200,'1200000000','1'],
    [1440,'1400000000','1'],[1441,'5602777775','4'],[1920,'1733333000','1']])assert.deepEqual(at(tempo,tick),{numerator,denominator},`tick ${tick}`)
  // 0xe350: 29.97 fps drop-frame, 80 ticks per frame; its 1000000 us tempo has no effect.
  const smpte=pattern(0xe350,[[0,255,81,3,0x0f,0x42,0x40,0,0x90,60,100,0x92,0x60,0x80,60,0,0,255,47,0]])
  for(const [tick,numerator,denominator] of [[100,'125125000','3'],[1200,'500500000','1'],[2400,'1001000000','1']])
    assert.deepEqual(at(smpte,tick),{numerator,denominator},`SMPTE tick ${tick}`)
})
