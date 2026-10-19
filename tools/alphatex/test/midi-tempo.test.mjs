import test from 'node:test'
import assert from 'node:assert/strict'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { importMidiSource, exportMidiSource, midiSourcePattern, editMidiSourceTempos, validateMidiSource } from '../midi-source.mjs'
import { newEditor, editorCommand, editorAction } from '../sequencer-editor.mjs'
import { sourceTempos, selectedTempo } from '../midi-source-editor.mjs'
import { saveProject, loadProject } from '../sequencer-files.mjs'
import { newArrangement, editArrangement } from '../arrangement.mjs'
import { importPhraseDocument } from '../phrase-arrangement.mjs'
midiFiles(JZZ)
const chunk=(type,data)=>{const h=Buffer.alloc(8);h.write(type);h.writeUInt32BE(data.length,4);return Buffer.concat([h,Buffer.from(data)])}
const smf=(tracks,{format=1,division=480}={})=>{const h=Buffer.alloc(6);h.writeUInt16BE(format);h.writeUInt16BE(tracks.length,2);h.writeUInt16BE(division,4);return Buffer.concat([chunk('MThd',h),chunk('Xtra',[0,255,9]),...tracks.map(t=>chunk('MTrk',t))])}
const conductor=[0,255,81,3,7,161,32,0,255,0x7f,2,5,6,0x83,0x60,255,81,3,15,66,64,0x83,0x60,255,47,0]
const notes=[0,0xb0,1,77,0,0x90,60,96,0x83,0x60,0x80,60,45,0,0x90,64,90,0x83,0x60,0x80,64,44,0,255,47,0]
const fixture=()=>importMidiSource(smf([conductor,notes]))
const ticks=source=>midiSourcePattern(source).notes.map(({id,off,track,port,channel,pitch,velocity,start,duration})=>({id,off,track,port,channel,pitch,velocity,start,duration}))
function client(file){const worker=new Worker(new URL(file,import.meta.url));let id=0;return{worker,async request(job){const reply=once(worker,'message');worker.postMessage({...job,id:++id});const[r]=await reply;assert.equal(r.ok,true,r.error);return r.result}}}

test('source tempo map selection, insert/change/move/remove and history change seconds while retaining all note ticks and original chunks',()=>{
 const source=fixture();let e=newEditor(source);const cmd=line=>{e=editorCommand(e,line).editor}
 assert.equal(midiSourcePattern(source).seconds,1.5)
 cmd('tempos');assert.equal(selectedTempo(e).id,'0:0')
 cmd('tempo-value 60');assert.equal(e.performance.seconds,2)
 cmd('tempo 120 0.5');assert.equal(e.performance.seconds,1.75);assert.equal(selectedTempo(e).id,'new:1')
 cmd('tempo-move 0.75');assert.equal(e.performance.seconds,1.875)
 const moved=e.project;cmd('tempo-remove');assert.equal(e.performance.seconds,2)
 cmd('undo');assert.deepEqual(e.project,moved);cmd('redo');assert.equal(e.performance.seconds,2);cmd('undo')
 assert.deepEqual(ticks(e.project),ticks(source));assert.equal(e.project.original,source.original)
 const output=Buffer.from(exportMidiSource(e.project)),decoded=new JZZ.MIDI.SMF(output)
 assert.deepEqual([...[...decoded].find(t=>t.type==='MTrk')].filter(v=>v.ff===0x51).map(v=>[v.tt,v.getTempo()]),[[0,1000000],[360,500000],[480,1000000]])
 assert.ok(output.includes(chunk('Xtra',[0,255,9])));assert.ok(output.includes(chunk('MTrk',notes)))
 assert.deepEqual(midiSourcePattern(importMidiSource(output)).notes.map(n=>n.durationSeconds),[.875,1])
 assert.deepEqual(exportMidiSource(source),exportMidiSource(fixture()))
})

test('tempo edits share expression-order membership and explicit SMF2 pattern authority while SMPTE clocks stay unchanged',()=>{
 const track=[0,0x90,60,96,0,0xb0,1,77,0x92,0x60,0x80,60,45,0,255,47,0]
 const source=importMidiSource(smf([track,track],{format:2,division:0xe350}))
 let e=newEditor(source);assert.throws(()=>editorCommand(e,'tempo 90'),/pattern explicitly/)
 const cmd=line=>{e=editorCommand(e,line).editor};cmd('pattern 2');const before=e.performance
 cmd('channel 1');cmd('cc 1 0 0');cmd('event-before first-note');const order=structuredClone(e.project.orders)
 cmd('tempo 90 0');assert.equal(e.project.insertions.at(-1).track,1);assert.equal(e.project.orders[0].events.length,order[0].events.length+1)
 const added=selectedTempo(e).id;cmd('tempo-value 123');cmd('tempo-move 1');validateMidiSource(e.project)
 assert.ok(!e.project.orders?.some(v=>v.events.includes(added)));assert.deepEqual(e.performance.notes,before.notes)
 cmd('tempo-remove');assert.deepEqual(e.project.orders,order);cmd('undo');cmd('undo');cmd('undo');cmd('undo');assert.deepEqual(e.project.orders,order)
 assert.deepEqual(midiSourcePattern(e.project,{pattern:0}),midiSourcePattern(source,{pattern:0}))
 assert.ok(Buffer.from(exportMidiSource(e.project)).includes(chunk('MTrk',track)))
})

test('tempo event authority, simultaneous collisions and encoded microsecond bounds refuse transactionally',()=>{
 const source=fixture();let e=newEditor(source);const original=structuredClone(e.project)
 for(const cmd of ['tempo NaN','tempo Infinity','tempo 0','tempo -1','tempo 1','tempo 120000001','tempo 120 -1','tempo-event 1:0'])assert.throws(()=>editorCommand(e,cmd))
 assert.deepEqual(e.project,original)
 assert.throws(()=>editMidiSourceTempos(source,[{kind:'remove',id:'0:1'}]),/tempo event/)
 assert.throws(()=>validateMidiSource({...source,insertions:[{id:'new:1',track:0,tick:0,kind:'meta',type:0x21,data:[1]}]}),/Set Tempo/)
 for(const data of [[0,0,0],[1,2],[0,0,256]])assert.throws(()=>validateMidiSource({...source,changes:[{id:'0:0',tick:0,data}]}))
 assert.throws(()=>validateMidiSource({...source,changes:[{id:'0:0',tick:0,bytes:[0x90,60,96]}]}))
 const many=importMidiSource(smf([[0,255,81,3,7,161,32,0,255,81,3,15,66,64,0,255,47,0],notes]))
 e=newEditor(many);assert.throws(()=>editorCommand(e,'tempo 90 0'),/Several tempo/)
 e=editorCommand(e,'tempo-event 0:1').editor;e=editorCommand(e,'tempo-value 90').editor
 assert.equal(sourceTempos(e)[0].micros,500000);assert.equal(sourceTempos(e)[1].micros,666667)
 e=editorCommand(e,'tempo-event 0:0').editor;e=editorCommand(e,'tempo-value 60000000').editor;assert.equal(selectedTempo(e).micros,1)
 e=editorCommand(e,`tempo-value ${60e6/0xffffff}`).editor;assert.equal(selectedTempo(e).micros,0xffffff)
})

test('real workers carry edited timing into MIDI plans, portable source saves and immutable arrangement variants',async()=>{
 const directory=await mkdtemp(join(tmpdir(),'masc-midi-tempo-')),sequence=client('../sequencer-worker.mjs'),arrange=client('../arrangement-worker.mjs')
 try{
  const source=fixture(),e=editorCommand(newEditor(source),'tempo 60 0').editor
  const path=join(directory,'source.json');await saveProject(path,e.project);assert.deepEqual((await loadProject(path)).project,e.project)
  const plan=await sequence.request({project:e.project,path:join(directory,'source-plan.json'),cancel:new SharedArrayBuffer(4),options:{format:'midi',midiOutput:'123'}})
  const timeline=JSON.parse(await readFile(plan.path,'utf8'));assert.equal(timeline.duration,2)
  assert.ok(timeline.events.some(event=>event.seconds===1&&event.bytes[0]===0x90&&event.bytes[1]===64))
  let project=newArrangement();const first=importPhraseDocument(project,source);project=first.project
  const variant=await arrange.request({kind:'import-phrase',project,document:e.project});assert.deepEqual(variant.project.assets[0].source,source)
  project=variant.project;project=editArrangement(project,{kind:'lane-add',sourceKind:'midi',name:'Tempo variants'})
  project=editArrangement(project,{kind:'region-add',lane:project.lanes[0].id,asset:variant.asset,name:'Edited tempo',position:0,offset:0,extent:960,repeat:1})
  const prepared=await arrange.request({kind:'prepare-midi',project,directory,midiOutput:'123'})
  const backing=JSON.parse(await readFile(prepared.path,'utf8'));assert.equal(backing.duration,2);assert.equal(backing.regions[0].sourceEnd-backing.regions[0].sourceStart,2)
 }finally{await Promise.all([sequence.worker.terminate(),arrange.worker.terminate()]);await rm(directory,{recursive:true,force:true})}
})
