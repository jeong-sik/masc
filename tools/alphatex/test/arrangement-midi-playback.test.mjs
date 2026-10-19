import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { importMidiSource } from '../midi-source.mjs'
import { newArrangement, editArrangement } from '../arrangement.mjs'
import { prepareArrangementMidi } from '../arrangement-playback.mjs'
import { arrangementEditor, arrangementCommand } from '../arrangement-editor.mjs'
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
  assert.deepEqual(plan.regions,[{id:'region-1',source:'["a",null]',startSeconds:.5,sourceStart:.25,sourceEnd:1.5,repeatCount:2_000_000}])
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
