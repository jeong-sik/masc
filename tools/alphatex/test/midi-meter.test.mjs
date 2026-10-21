import test from 'node:test'
import assert from 'node:assert/strict'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { importMidiSource, exportMidiSource, midiSourcePattern, editMidiSourceMeters, validateMidiSource } from '../midi-source.mjs'
import { newEditor, editorCommand, editorAction, editorView } from '../sequencer-editor.mjs'
import { sourceMeters, selectedMeter } from '../midi-source-editor.mjs'
import { saveProject, loadProject } from '../sequencer-files.mjs'
import { newArrangement } from '../arrangement.mjs'
import { importPhraseDocument } from '../phrase-arrangement.mjs'
midiFiles(JZZ)
const chunk=(tag,data)=>{const h=Buffer.alloc(8);h.write(tag);h.writeUInt32BE(data.length,4);return Buffer.concat([h,Buffer.from(data)])}
const smf=(tracks,{format=1,division=480}={})=>{const h=Buffer.alloc(6);h.writeUInt16BE(format);h.writeUInt16BE(tracks.length,2);h.writeUInt16BE(division,4);return Buffer.concat([chunk('MThd',h),chunk('Xtra',[0,255,9]),...tracks.map(t=>chunk('MTrk',t))])}
const conductor=[0,255,81,3,7,161,32,0,255,88,4,4,2,36,12,0,255,0x7f,2,5,6,0x83,0x60,255,88,4,3,2,24,8,0x83,0x60,255,47,0]
const notes=[0,0xb0,1,77,0,0x90,60,96,0x83,0x60,0x80,60,45,0,0xf0,2,1,0xf7,0,0x90,64,90,0x83,0x60,0x80,64,44,0,255,47,0]
const fixture=()=>importMidiSource(smf([conductor,notes]))
const clocks=p=>{const {notes,seconds,ticks,timing}=midiSourcePattern(p);return {notes,seconds,ticks,timing}}
const meters=p=>new JZZ.MIDI.SMF(Buffer.from(exportMidiSource(p))).filter(t=>t.type==='MTrk').flatMap((t,track)=>[...t].filter(e=>e.ff===0x58).map(e=>[track,e.tt,[...e.dd].map(c=>c.charCodeAt(0))]))
function client(file){const worker=new Worker(new URL(file,import.meta.url));let id=0;return{worker,async request(job){const reply=once(worker,'message');worker.postMessage({...job,id:++id});const[r]=await reply;assert.equal(r.ok,true,r.error);return r.result}}}

test('time-signature maps preserve all four fields, original chunks and note/tempo clocks through edits and history',()=>{
 const original=fixture();let e=newEditor(original);const cmd=line=>{e=editorCommand(e,line).editor}
 cmd('meters');assert.equal(selectedMeter(e).id,'0:1')
 cmd('meter-value 7 8');assert.deepEqual([selectedMeter(e).clocks,selectedMeter(e).notated32nds],[36,12])
 cmd('meter 5 16 0.5 48 16');assert.equal(selectedMeter(e).id,'new:1');assert.equal(e.project.insertions.at(-1).track,0)
 cmd('meter-move 0.75');const moved=e.project;cmd('meter-remove');cmd('undo');assert.deepEqual(e.project,moved);cmd('redo');cmd('undo')
 assert.deepEqual(meters(e.project),[[0,0,[7,3,36,12]],[0,360,[5,4,48,16]],[0,480,[3,2,24,8]]])
 e=editorAction(e,{kind:'move',ticks:480});assert.deepEqual(editorView(e).meter,[3,4])
 assert.deepEqual(clocks(e.project),clocks(original));assert.equal(e.project.original,original.original)
 const output=Buffer.from(exportMidiSource(e.project));assert.ok(output.includes(chunk('Xtra',[0,255,9])));assert.ok(output.includes(chunk('MTrk',notes)))
 assert.deepEqual(clocks(importMidiSource(output)).notes.map(n=>[n.start,n.duration,n.seconds,n.durationSeconds]),clocks(original).notes.map(n=>[n.start,n.duration,n.seconds,n.durationSeconds]))
})

test('SMPTE and independent patterns preserve frame clocks, expression-order membership and other pattern bytes',()=>{
 const track=[0,0x90,60,96,0,0xb0,1,77,0x92,0x60,0x80,60,45,0,255,47,0]
 const source=importMidiSource(smf([track,track],{format:2,division:0xe350}));let e=newEditor(source)
 assert.throws(()=>editorCommand(e,'meter 7 8'),/pattern explicitly/)
 const cmd=line=>{e=editorCommand(e,line).editor};cmd('pattern 2');const before=e.performance
 cmd('channel 1');cmd('cc 1 0 0');cmd('event-before first-note');const order=structuredClone(e.project.orders)
 cmd('meter 7 8 0');const id=selectedMeter(e).id;assert.equal(e.project.insertions.at(-1).track,1)
 assert.equal(e.project.orders[0].events.length,order[0].events.length+1)
 cmd('meter-value 11 16');cmd('meter-move 1');validateMidiSource(e.project)
 assert.ok(!e.project.orders?.some(o=>o.events.includes(id)));assert.deepEqual(e.performance.notes,before.notes)
 cmd('meter-remove');assert.deepEqual(e.project.orders,order)
 assert.deepEqual(midiSourcePattern(e.project,{pattern:0}),midiSourcePattern(source,{pattern:0}))
 assert.ok(Buffer.from(exportMidiSource(e.project)).includes(chunk('MTrk',track)))
})

test('map authority, simultaneous collisions and byte bounds refuse transactionally while opaque originals survive',()=>{
 const source=fixture();let e=newEditor(source)
 for(const line of ['meter 0 4','meter 256 4','meter 3 3','meter 4 0','meter 3 Infinity','meter 3 4 -1','meter 3 4 0 256 8','meter 3 4 0 24 -1','meter 3 4 0 24','meter-event 1:0'])assert.throws(()=>editorCommand(e,line))
 assert.deepEqual(e.project,source)
 assert.throws(()=>editMidiSourceMeters(source,[{kind:'remove',id:'0:0'}]),/time-signature/)
 assert.throws(()=>validateMidiSource({...source,changes:[{id:'0:1',tick:0,data:[1,2,3]}]}))
 const many=importMidiSource(smf([[0,255,88,4,3,2,24,8,0,255,88,4,7,3,36,12,0,255,47,0]]))
 e=newEditor(many);assert.throws(()=>editorCommand(e,'meter 5 8 0'),/Several time/)
 e=editorCommand(e,'meter-event 0:1').editor;e=editorCommand(e,'meter-value 5 16').editor
 assert.deepEqual(sourceMeters(e).map(m=>[m.numerator,m.denominator,m.clocks,m.notated32nds]),[[3,4,24,8],[5,16,36,12]])
 e=editorCommand(e,`meter-value 255 ${2**255} 255 255`).editor
 assert.deepEqual(meters(e.project).at(-1)[2],[255,255,255,255])
 const opaque=importMidiSource(smf([[0,255,88,2,3,4,0,255,47,0]]));assert.deepEqual(exportMidiSource(newEditor(opaque).project),exportMidiSource(opaque))
})

test('actual workers and portable saves preserve the edited map as an independent arrangement variant without retiming',async()=>{
 const directory=await mkdtemp(join(tmpdir(),'masc-source-meter-')),sequence=client('../sequencer-worker.mjs'),arrange=client('../arrangement-worker.mjs')
 try{
  const original=fixture(),e=editorCommand(newEditor(original),'meter 7 8 0').editor,path=join(directory,'source.json')
  await saveProject(path,e.project);const loaded=(await loadProject(path)).project;assert.deepEqual(loaded,e.project);assert.deepEqual(meters(loaded),[[0,0,[7,3,36,12]],[0,480,[3,2,24,8]]])
  const plan=await sequence.request({project:loaded,path:join(directory,'midi-plan.json'),cancel:new SharedArrayBuffer(4),options:{format:'midi',midiOutput:'123'}})
  const wire=JSON.parse(await readFile(plan.path,'utf8'));assert.equal(wire.duration,1)
  assert.ok(wire.events.some(event=>event.seconds===.5&&event.bytes[0]===0x90&&event.bytes[1]===64))
  const first=importPhraseDocument(newArrangement(),original)
  const variant=await arrange.request({kind:'import-phrase',project:first.project,document:loaded})
  assert.equal(variant.project.assets.length,2);assert.deepEqual(variant.project.assets[0].source,original)
  assert.deepEqual(meters(variant.project.assets[1].source),meters(loaded));assert.deepEqual(clocks(variant.project.assets[1].source),clocks(original))
  // Exercise the direct handoff consumer, including opaque and simultaneous
  // originals. An exact SMF power of two is representable beyond safe integers.
  for(const power of [0,53,255]) {
   const edited=editorCommand(newEditor(original),`meter 7 ${2**power} 0`).editor.project
   const result=await sequence.request({project:edited,cancel:new SharedArrayBuffer(4),options:{format:'arrangement'}})
   assert.deepEqual(result.project.meter,[7,2**power]);assert.deepEqual(result.project.assets[0].source,edited)
   await saveProject(join(directory,`arrangement-${power}.json`),result.project)
   assert.deepEqual((await loadProject(join(directory,`arrangement-${power}.json`))).project,result.project)
  }
  const opaque=importMidiSource(smf([[0,255,88,4,0,2,24,8,0,255,47,0]]))
  const repaired=editorCommand(newEditor(opaque),'meter 7 8 0').editor.project
  const repair=await sequence.request({project:repaired,cancel:new SharedArrayBuffer(4),options:{format:'arrangement'}})
  assert.deepEqual(repair.project.meter,[7,8]);assert.deepEqual(repair.project.assets[0].source,repaired)
  const simultaneous=importMidiSource(smf([[0,255,88,4,3,2,24,8,0,255,88,4,7,3,36,12,0,255,47,0]]))
  const selected=editorCommand(editorCommand(newEditor(simultaneous),'meter-event 0:1').editor,'meter-value 5 16').editor.project
  const handoff=await sequence.request({project:selected,cancel:new SharedArrayBuffer(4),options:{format:'arrangement'}})
  assert.deepEqual(handoff.project.meter,[5,16])
 }finally{await Promise.all([sequence.worker.terminate(),arrange.worker.terminate()]);await rm(directory,{recursive:true,force:true})}
})
