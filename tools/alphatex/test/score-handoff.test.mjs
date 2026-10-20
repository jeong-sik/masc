import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { scoreDocument } from '../score-handoff.mjs'
import { midiForScore } from '../engine.mjs'
import { exportMidiSource, midiSourcePattern, importMidiSource, validateMidiSource } from '../midi-source.mjs'
import { newEditor, editorCommand, editorHarmony } from '../sequencer-editor.mjs'
import { arrangementFromMidiSource } from '../phrase-arrangement.mjs'
import { loadArrangement, saveArrangement } from '../arrangement-files.mjs'

const source = String.raw`\title "Current score"
\tempo 80
\track "Bass" {instrument 33}
\ro :4 3.3 5.3 r r | \tempo 120 :4 7.3 5.3 r r \rc 2 |
\track "Keys" {instrument 0}
:4 C4 D4 r r | :4 E4 D4 r r |`
const bytes = value => Buffer.from(exportMidiSource(value))

test('actual score worker retains the current notation, solo/full performance and original official MIDI bytes',async()=>{
 for(const tracks of [undefined,[1]]){
  const snapshot={source,...(tracks ? {tracks}: {})},document=await scoreDocument(snapshot)
  const official=midiForScore(source,{smf1Mode:true,tracks})
  assert.deepEqual(bytes(document),Buffer.from(official.midi.toBinary()))
  assert.equal(document.name,'Current score');assert.equal(document.notation.source,source)
  assert.deepEqual(document.notation.tracks,tracks)
  const performance=midiSourcePattern(document)
  assert.ok(performance.notes.length>0);assert.ok(performance.events.filter(e=>e.kind==='meta'&&e.type===0x51).length>1)
  if(tracks)assert.ok(performance.notes.every(note=>note.channel===2))
  const arranged=arrangementFromMidiSource(document)
  assert.deepEqual(arranged.project.assets[0].source,document)
  assert.equal(arranged.project.clips[0].offset,0);assert.equal(arranged.project.clips[0].extent,performance.ticks)
  assert.equal(arranged.project.tempo,80)
 }
})

test('score edit, harmony/voicing, actual arrange worker and portable reopen retain notation and original performance',async()=>{
 const document=await scoreDocument({source,tracks:[1]}),original=bytes(document)
 let editor=newEditor(document),performance=midiSourcePattern(document)
 editor=editorCommand(editor,'select '+performance.notes[0].id).editor
 const beat=performance.ticks/performance.timing.ppq+1
 editor=editorCommand(editor,`chord Dm7 ${beat} 4 drop2 4 0`).editor
 editor=editorCommand(editor,`cursor ${beat} C4`).editor
 assert.ok(editorHarmony(editor).pitches.length===4)
 assert.deepEqual(bytes(document),original);assert.equal(editor.project.original,document.original)
 assert.equal(editor.project.notation.source,source)
 assert.equal(editorCommand(editor,'arrange').effect.kind,'arrange')
 const directory=await mkdtemp(join(tmpdir(),'masc-score-arrange-')),worker=new Worker(new URL('../sequencer-worker.mjs',import.meta.url))
 try{
  const result=once(worker,'message');worker.postMessage({id:1,project:editor.project,cancel:new SharedArrayBuffer(4),options:{format:'arrangement',pattern:editor.pattern}})
  const [reply]=await result;assert.equal(reply.ok,true,reply.error)
  const asset=reply.result.project.assets[0];assert.deepEqual(asset.source,editor.project)
  const path=join(directory,'portable','song.json');await saveArrangement(path,reply.result.project,null,{sourceRoot:directory})
  assert.deepEqual((await loadArrangement(path)).project,reply.result.project)
  assert.deepEqual(bytes(asset.source),bytes(editor.project));assert.deepEqual(Buffer.from(asset.source.original,'base64'),original)
 }finally{await worker.terminate();await rm(directory,{recursive:true,force:true})}
})

test('independent SMF2 pattern selection is required and survives placement without merging performances',()=>{
 const chunk=p=>{const b=Buffer.from([0,0x90,p,100,0x83,0x60,0x80,p,77,0,0xff,0x2f,0]);const h=Buffer.alloc(8);h.write('MTrk');h.writeUInt32BE(b.length,4);return Buffer.concat([h,b])}
 const wire=Buffer.concat([Buffer.from('4d546864000000060002000201e0','hex'),chunk(60),chunk(62)]),document=importMidiSource(wire)
 assert.throws(()=>arrangementFromMidiSource(document),/explicitly/)
 const arranged=arrangementFromMidiSource(document,{pattern:1})
 assert.equal(arranged.project.clips[0].pattern,1);assert.deepEqual(bytes(arranged.project.assets[0].source),wire)
})

test('conversion abort and official source refusal drain the worker and never substitute a blank document',async()=>{
 const controller=new AbortController(),pending=scoreDocument({source},{signal:controller.signal});controller.abort()
 await assert.rejects(pending,{name:'AbortError'})
 await assert.rejects(scoreDocument({source:'\\staff {score tab} :4 5.3'}))
 await assert.rejects(scoreDocument({source,tracks:[99]}),/existing score track/)
 const document=await scoreDocument({source})
 for(const notation of [{kind:'other',source},{kind:'alphatex',source:''},{kind:'alphatex',source,tracks:[]},{kind:'alphatex',source,tracks:[0,0]}])assert.throws(()=>validateMidiSource({...document,notation}))
})
