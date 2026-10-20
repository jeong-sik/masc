import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { newEditor, editorCommand, editorAction } from '../sequencer-editor.mjs'
import { stepPacket, openStepInput } from '../step-input.mjs'
import { openMidiInput } from '../midi-input.mjs'
import { importMidiSource, midiSourcePattern } from '../midi-source.mjs'
import { saveProject, loadProject, projectMidi } from '../sequencer-files.mjs'
midiFiles(JZZ)
const packet = words => ({ kind: 'midi', protocol: 2, source: '10', timestampOrigin: 'packet', words })
const on = (pitch, velocity = 0xffff, group = 3, channel = 5) => [(0x40900000 | group << 24 | channel << 16 | pitch << 8) >>> 0, (velocity << 16) >>> 0]
const off = (pitch, velocity = 0, group = 3, channel = 5) => [(0x40800000 | group << 24 | channel << 16 | pitch << 8) >>> 0, (velocity << 16) >>> 0]
const command = (editor, text) => editorCommand(editor, text).editor
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done }); return { promise, resolve } }

test('held-key identities collect a chord, ignore unrelated releases, insert once and undo once across tracks', () => {
  let editor = command(newEditor(), 'note C2 0 4'), pending = null
  editor = command(editor, 'track-add Keys')
  const original = editor.project
  let result = stepPacket(editor, pending, packet([...on(60, 0x8000), ...on(64, 0xffff, 4, 1), ...on(67, 0x4000)]))
  pending = result.pending; assert.equal(result.editor, editor)
  result = stepPacket(editor, pending, packet([...off(60, 0, 4), ...off(60, 0, 3, 1), ...off(60, 0x2000)]))
  pending = result.pending; assert.equal(result.editor, editor); assert.equal(pending.held.size, 2)
  result = stepPacket(editor, pending, packet([...off(64, 0x4000, 4, 1), ...off(67, 0x6000)]))
  editor = result.editor; assert.equal(result.pending, null); assert.equal(result.inserted, 3)
  assert.deepEqual(editor.project.tracks[0], original.tracks[0])
  assert.deepEqual(editor.project.tracks[1].notes.map(n => [n.pitch,n.start,n.duration,n.velocity]), [[60,0,960,64],[64,0,960,127],[67,0,960,32]])
  assert.equal(editor.tick,960); assert.equal(editor.undo.length,3)
  assert.deepEqual(command(editor,'undo').project, original)
})
test('step lengths determine musical advance; MIDI2 zero attack remains a note, sustain does not replace physical releases', () => {
  let editor = { ...newEditor(), duration: 240 }
  const result = stepPacket(editor,null,packet([...on(60,0),0x40b54000,0xffffffff,...off(60),...on(62),...off(62)]))
  assert.deepEqual(result.editor.project.tracks[0].notes.map(n=>[n.start,n.duration,n.velocity]), [[0,240,1],[240,240,127]])
  assert.equal(result.editor.tick,480);assert.equal(result.editor.undo.length,2)
  editor = command(result.editor,'undo'); assert.equal(editor.project.tracks[0].notes.length,1)
})
test('repeated same-key attacks require their own releases and cannot silently collapse overlapping voices', () => {
  const editor=newEditor(), held=stepPacket(editor,null,packet([...on(60),...on(60),...off(60)]))
  assert.equal(held.editor,editor);assert.equal(held.pending.held.values().next().value.length,1)
  const before=structuredClone(held.pending.notes)
  assert.throws(()=>stepPacket(editor,held.pending,packet(off(60))),/Overlapping/)
  assert.deepEqual(held.pending.notes,before);assert.equal(editor.project.tracks[0].notes.length,0)
})
test('attributes, reset and target failures never partly commit a packet or retarget held keys', () => {
  const editor=newEditor(), complete=[...on(60),...off(60)]
  for(const words of [[...complete,0x40903d03,0xffff1234],[...complete,0x40b57b00,0],[...complete,0x10ff0000]]){
    assert.throws(()=>stepPacket(editor,null,packet(words)));assert.equal(editor.project.tracks[0].notes.length,0)
  }
  const held=stepPacket(editor,null,packet(on(60))).pending
  for(const next of [{...editor,tick:240},{...editor,project:structuredClone(editor.project)},{...editor,duration:240}])assert.throws(()=>stepPacket(next,held,packet(off(60))),/context changed/)
  const endpoint={...editor,tick:editor.project.length}
  assert.throws(()=>stepPacket(endpoint,null,packet(complete)),/note start/)
})
function sourceFile(format=1, smpte=false) {
  const file=smpte?new JZZ.MIDI.SMF(format,25,40):new JZZ.MIDI.SMF(format,1001)
  file.push(new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.smfMidiPort(3)).add(0,JZZ.MIDI.control(4,1,77)).add(8008,JZZ.MIDI.smfEndOfTrack()))
  file.push(new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.noteOn(1,48,70)).add(1001,JZZ.MIDI.noteOff(1,48,12)).add(8008,JZZ.MIDI.smfEndOfTrack()))
  return importMidiSource(file.toUint8Array())
}
for(const [format,smpte] of [[1,false],[2,false],[1,true]])test(`source step entry retains original clock, release, port and unrelated events (${format}, SMPTE ${smpte})`, async () => {
  const original=sourceFile(format,smpte)
  let editor=newEditor(original,{pattern:0});editor=command(editor,'track 1');editor=command(editor,'channel 5')
  editor={...editor,tick:1001,duration:333}
  const words=[...on(60,0xa000),...on(64,0xc000),...off(60,0x8000),...off(64,0x4000)]
  const result=stepPacket(editor,null,packet(words));editor=result.editor
  const inserted=editor.performance.notes.filter(n=>n.track===0)
  assert.deepEqual(inserted.map(n=>[n.start,n.duration,n.channel,n.port,n.pitch,n.velocity]),[[1001,333,4,3,60,80],[1001,333,4,3,64,96]])
  const events=new Map(editor.performance.events.map(e=>[e.id,e]))
  assert.deepEqual(inserted.map(n=>events.get(n.off).bytes),[[0x84,60,64],[0x84,64,32]])
  assert.deepEqual(editor.project.original,original.original);assert.equal(editor.tick,1334)
  assert.deepEqual(command(editor,'undo').project,original)
  const reparsed=importMidiSource(projectMidi(editor.project))
  const parsed=midiSourcePattern(reparsed,{pattern:0})
  assert.deepEqual(parsed.notes.filter(n=>n.track===0).map(n=>[n.start,n.duration,n.pitch]),[[1001,333,60],[1001,333,64]])
  assert.deepEqual(midiSourcePattern(original,{pattern:0}).events.filter(e=>e.kind==='channel' && e.bytes[0]>>>4!==9 && e.bytes[0]>>>4!==8),
    parsed.events.filter(e=>e.kind==='channel' && e.bytes[0]>>>4!==9 && e.bytes[0]>>>4!==8))
})
const fixture=fileURLToPath(new URL('./fixtures/midi-input-owner.mjs',import.meta.url))
function owned(mode, options={}) {
  let editor=newEditor(), task=Promise.resolve(), child
  const openInput=args=>openMidiInput({...args,spawnProcess(exe,args,config){child=spawn(process.execPath,[fixture,mode,...args],config);return child}})
  const owner=openStepInput({source:'10',getEditor:()=>editor,adoptEditor:next=>{editor=next},enqueue(action){const decision=task.then(action);task=decision.catch(()=>{});return decision},...options,openInput})
  return {owner,get editor(){return editor},get child(){return child},replace(next){editor=next}}
}
test('normal close drains an already queued MIDI decision before saved/reopened/exported state', async () => {
  const gate=deferred(),entered=deferred();let queue=gate.promise
  const input=owned('step-chord',{enqueue(action){entered.resolve();const decision=queue.then(action);queue=decision.catch(()=>{});return decision}})
  await input.owner.ready;await entered.promise;input.owner.stop();gate.resolve();await input.owner.completion
  assert.notEqual(input.child.exitCode??input.child.signalCode,null)
  assert.deepEqual(input.editor.project.tracks[0].notes.map(n=>[n.pitch,n.velocity]),[[60,72],[64,127]])
  const dir=await mkdtemp(join(tmpdir(),'masc-step-state-'))
  try{
    const path=join(dir,'keys.json');await saveProject(path,input.editor.project)
    const reopened=(await loadProject(path)).project
    assert.deepEqual(reopened,input.editor.project)
    const smf=new JZZ.MIDI.SMF(projectMidi(reopened))
    assert.deepEqual([...smf[1]].filter(e=>e.isNoteOn()).map(e=>[e.tt,e.getNote()]),[[0,60],[0,64]])
  }finally{await rm(dir,{recursive:true,force:true})}
})
test('context cancellation joins a queued consumer and child without applying its notes', async () => {
  const gate=deferred(),entered=deferred();let queue=gate.promise
  const input=owned('step-chord',{enqueue(action){entered.resolve();const decision=queue.then(action);queue=decision.catch(()=>{});return decision}})
  await input.owner.ready;await entered.promise;input.owner.cancel(new Error('track changed'))
  let settled=false;input.owner.completion.catch(()=>{settled=true})
  await new Promise(resolve=>input.child.once('close',resolve));assert.equal(settled,false)
  gate.resolve();await assert.rejects(input.owner.completion,/track changed/)
  assert.equal(input.editor.project.tracks[0].notes.length,0)
})
test('normal stop discards an incomplete held chord without inserting a partial note', async () => {
  const held=deferred(),input=owned('step-held',{onState:state=>{if(state.held)held.resolve()}})
  await input.owner.ready;await held.promise;input.owner.stop();await input.owner.completion
  assert.equal(input.editor.project.tracks[0].notes.length,0)
})
test('step commands use the same explicit effect grammar for phrase and source documents', () => {
  for(const editor of [newEditor(),newEditor(sourceFile())]){
    assert.deepEqual(editorCommand(editor,'step-input -123').effect,{kind:'step-input',source:'-123'})
    assert.deepEqual(editorCommand(editor,'step-stop').effect,{kind:'step-stop'})
    assert.throws(()=>editorCommand(editor,'step-input'));assert.throws(()=>editorCommand(editor,'step-stop extra'))
  }
})
