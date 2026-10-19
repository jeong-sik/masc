import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { newEditor, editorCommand } from '../sequencer-editor.mjs'
import { newArrangement, editArrangement } from '../arrangement.mjs'
import { arrangementEditor, arrangementImported, arrangementCommand } from '../arrangement-editor.mjs'
import { loadArrangement } from '../arrangement-files.mjs'
import { projectMidi } from '../sequencer-files.mjs'
import { exportMidiSource, importMidiSource } from '../midi-source.mjs'
import { arrangementFromPhrase, phraseDocument, verifyPhraseSnapshot } from '../phrase-arrangement.mjs'

const compose=()=>{
 let editor=newEditor()
 for(const line of ['tempo 120','meter 3 4','length 8','chord Cmaj7 0 4 drop2 4 0','track-add Bass','program 33','note C2 0 4 108'])editor=editorCommand(editor,line).editor
 return editor.project
}
function client(file) {
 const worker=new Worker(new URL(file,import.meta.url));let id=0
 return {worker,async request(job){const reply=once(worker,'message');worker.postMessage({...job,id:++id});return(await reply)[0]}}
}
const ok=reply=>{assert.equal(reply.ok,true,reply.error);return reply.result}

test('phrase snapshots preserve editable voicing and independent MIDI data without sharing mutable state',()=>{
 const phrase=compose(), result=arrangementFromPhrase(phrase),asset=result.project.assets[0]
 assert.deepEqual(asset.phrase,phrase);assert.notEqual(asset.phrase,phrase)
 assert.equal(result.project.tempo,120);assert.deepEqual(result.project.meter,[3,4])
 assert.deepEqual(Buffer.from(exportMidiSource(asset.source)),Buffer.from(projectMidi(phrase)))
 const draft=phraseDocument(result.project,asset.id)
 draft.tracks[0].notes[0].velocity=1
 assert.notDeepEqual(draft,asset.phrase);verifyPhraseSnapshot(asset)
 assert.equal(result.project.clips[0].extent,8*960)
 assert.throws(()=>arrangementFromPhrase(importMidiSource(projectMidi(phrase))))
})

test('actual phrase and arrangement workers carry harmony into backing, fork variants, undo and portable reopen',async()=>{
 const directory=await mkdtemp(join(tmpdir(),'masc-phrase-arrange-')),sequence=client('../sequencer-worker.mjs'),arrange=client('../arrangement-worker.mjs')
 try {
  const phrase=compose(),cancel=new SharedArrayBuffer(4)
  const seed=ok(await sequence.request({project:phrase,cancel,path:join(directory,'unused'),options:{format:'arrangement'}}))
  const original=structuredClone(seed.project),originalBytes=Buffer.from(exportMidiSource(original.assets[0].source))
  let draft=ok(await arrange.request({kind:'prepare-phrase',project:original,asset:seed.asset}))
  let editor=newEditor(draft);editor=editorCommand(editor,'track 1').editor;editor=editorCommand(editor,'transpose -12').editor
  const variant=ok(await arrange.request({kind:'import-phrase',project:original,document:editor.project}))
  assert.equal(variant.project.assets.length,2);assert.deepEqual(variant.project.clips,original.clips)
  assert.deepEqual(Buffer.from(exportMidiSource(variant.project.assets[0].source)),originalBytes)
  assert.notDeepEqual(variant.project.assets[1].phrase,phrase)
  let state=arrangementImported(arrangementEditor(original),variant)
  assert.deepEqual(arrangementCommand(state,'undo').editor.project,original)
  state=arrangementCommand(state,'place '+variant.asset+' 8').editor
  const path=join(directory,'portable','song.json')
  ok(await arrange.request({kind:'save',path,project:state.project,revision:null,sourceRoot:directory}))
  assert.deepEqual((await loadArrangement(path)).project,state.project)
  const prepared=ok(await arrange.request({kind:'prepare-midi',project:state.project,directory,midiOutput:'123'}))
  const timeline=JSON.parse(await readFile(prepared.path,'utf8'))
  assert.equal(timeline.regions.length,2);assert.equal(timeline.regions[1].startSeconds,4)
  assert.equal(timeline.sources.length,2)
  assert.deepEqual(Buffer.from(exportMidiSource(state.project.assets[0].source)),originalBytes)
  // A phrase/source disagreement is refused before editing, saving or playing.
  const corrupted=structuredClone(original);corrupted.assets[0].phrase.tracks[0].notes[0].velocity=1
  for(const job of [{kind:'prepare-phrase',asset:seed.asset},{kind:'prepare-midi',directory,midiOutput:'123'},{kind:'save',path:join(directory,'bad.json'),revision:null,sourceRoot:directory}]){
   const reply=await arrange.request({...job,project:corrupted});assert.equal(reply.ok,false);assert.match(reply.error,/snapshot disagree/)
  }
  Atomics.store(new Int32Array(cancel),0,1)
  assert.equal((await sequence.request({project:phrase,cancel,path:join(directory,'cancelled'),options:{format:'arrangement'}})).ok,false)
 }finally{await Promise.all([sequence.worker.terminate(),arrange.worker.terminate()]);await rm(directory,{recursive:true,force:true})}
})

test('original expressive source editing opens a clone and importing its variant retains every original byte',async()=>{
 const directory=await mkdtemp(join(tmpdir(),'masc-phrase-original-')),arrange=client('../arrangement-worker.mjs')
 try {
  const wire=Buffer.from('4d546864000000060000000101e04d54726b0000001500b0015800e0014100903c648360803c4d00ff2f00','hex')
  // Header length includes the complete source's channel expression and EOT.
  wire.writeUInt32BE(wire.length-22,18)
  const source=importMidiSource(wire),asset={id:'asset-1',kind:'midi',name:'Expressive',source}
  const project=editArrangement(newArrangement(),{kind:'asset-add',asset})
  const document=ok(await arrange.request({kind:'prepare-phrase',project,asset:asset.id}))
  assert.deepEqual(Buffer.from(exportMidiSource(document)),wire)
  const imported=ok(await arrange.request({kind:'import-phrase',project,document}))
  assert.equal(imported.project.assets.length,2)
  assert.deepEqual(Buffer.from(exportMidiSource(imported.project.assets[1].source)),wire)
  assert.deepEqual(Buffer.from(exportMidiSource(imported.project.assets[0].source)),wire)
  assert.equal(imported.project.assets[1].phrase,undefined)
 }finally{await arrange.worker.terminate();await rm(directory,{recursive:true,force:true})}
})
