import test from 'node:test'
import assert from 'node:assert/strict'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import {newEditor,editorCommand} from '../sequencer-editor.mjs'
import {importMidiSource,midiSourcePattern} from '../midi-source.mjs'
import {projectMidi} from '../sequencer-files.mjs'
midiFiles(JZZ)
const command=(editor,line)=>editorCommand(editor,line).editor
function source({attacks=[500],port=0,channel=0,format=1}={}) {
  const file=new JZZ.MIDI.SMF(format,1000)
  file.push(new JZZ.MIDI.SMF.MTrk().add(140,JZZ.MIDI.noteOn(0,60,80))
    .add(440,JZZ.MIDI.noteOff(0,60,45)).add(2000,JZZ.MIDI.smfEndOfTrack()))
  const raw=new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.smfMidiPort(port))
  for(const tick of attacks)raw.add(tick,JZZ.MIDI.noteOn(channel,60,77))
  file.push(raw.add(2000,JZZ.MIDI.smfEndOfTrack()))
  return newEditor(importMidiSource(file.toUint8Array()))
}

test('both quantizers refuse entering an unclosed attack even when an old diagnostic masks the new pair',()=>{
  for(const attacks of [[500],[300,500]])for(const selected of [false,true]) {
    let editor=source({attacks})
    if(selected)editor=command(editor,'select-all')
    const before=structuredClone(editor),bytes=projectMidi(editor.project)
    assert.throws(()=>command(editor,`${selected?'quantize-notes':'quantize'} 0.25`),/overlapping/)
    assert.deepEqual(editor,before)
    assert.deepEqual(projectMidi(editor.project),bytes)
  }
})

test('original unclosed overlaps remain supported, distinct routes and SMF2 patterns stay independent',()=>{
  for(const options of [{attacks:[300]},{port:1},{channel:1},{attacks:[600]}]) {
    const editor=source(options), next=command(editor,'quantize 0.25')
    assert.deepEqual(next.performance.notes.map(n=>[n.start,n.duration]),[[250,300]])
    const exported=midiSourcePattern(importMidiSource(projectMidi(next.project)))
    const onsets=events=>events.filter(e=>e.kind==='channel'&&e.track===1).map(e=>[e.tick,e.port,e.bytes])
    assert.deepEqual(onsets(exported.events),onsets(editor.performance.events))
    assert.deepEqual(command(next,'undo').project,editor.project)
  }
  const editor=command(source({format:2}),'pattern 1')
  const next=command(editor,'quantize 0.25')
  assert.equal(next.performance.notes[0].start,250)
  const originalTracks=new JZZ.MIDI.SMF(projectMidi(editor.project)),tracks=new JZZ.MIDI.SMF(projectMidi(next.project))
  assert.equal(tracks[1].dump(),originalTracks[1].dump())
})

test('actual end-tick ordering rejects a new raw overlap, including an already diagnosed endpoint attack',()=>{
  for(const masked of [false,true])for(const rawFirst of [false,true])for(const selected of [false,true]) {
    const file=new JZZ.MIDI.SMF(1,1000),paired=new JZZ.MIDI.SMF.MTrk()
      .add(140,JZZ.MIDI.noteOn(0,60,80)).add(440,JZZ.MIDI.noteOff(0,60,45)).add(2000,JZZ.MIDI.smfEndOfTrack())
    const raw=new JZZ.MIDI.SMF.MTrk()
    if(masked)raw.add(300,JZZ.MIDI.noteOn(0,60,70))
    raw.add(550,JZZ.MIDI.noteOn(0,60,77)).add(2000,JZZ.MIDI.smfEndOfTrack())
    file.push(rawFirst?raw:paired);file.push(rawFirst?paired:raw)
    let editor=newEditor(importMidiSource(file.toUint8Array()))
    if(selected)editor=command(editor,'select-all')
    const before=structuredClone(editor),line=`${selected?'quantize-notes':'quantize'} 0.25`
    if(rawFirst) {assert.throws(()=>command(editor,line),/overlapping/);assert.deepEqual(editor,before)}
    else {const next=command(editor,line);assert.deepEqual(next.performance.notes.map(n=>[n.start,n.duration]),[[250,300]])}
  }
})


test('paired attacks already diagnosed by another overlapping note cannot newly cross a moved release',()=>{
  for(const attackFirst of [false,true])for(const selected of [false,true]) {
    const file=new JZZ.MIDI.SMF(1,1000)
    const attack=new JZZ.MIDI.SMF.MTrk().add(550,JZZ.MIDI.noteOn(0,60,90)).add(800,JZZ.MIDI.noteOff(0,60,20)).add(2000,JZZ.MIDI.smfEndOfTrack())
    const moved=new JZZ.MIDI.SMF.MTrk().add(140,JZZ.MIDI.noteOn(0,60,80)).add(440,JZZ.MIDI.noteOff(0,60,45)).add(2000,JZZ.MIDI.smfEndOfTrack())
    const masking=new JZZ.MIDI.SMF.MTrk().add(300,JZZ.MIDI.noteOn(0,60,70)).add(700,JZZ.MIDI.noteOff(0,60,12)).add(2000,JZZ.MIDI.smfEndOfTrack())
    file.push(attackFirst?attack:moved);file.push(attackFirst?moved:attack);file.push(masking)
    let editor=command(newEditor(importMidiSource(file.toUint8Array())),`track ${attackFirst?2:1}`)
    if(selected)editor=command(editor,'select-all')
    const before=structuredClone(editor),line=`${selected?'quantize-notes':'quantize'} 0.25`
    if(attackFirst){assert.throws(()=>command(editor,line),/overlapping/);assert.deepEqual(editor,before)}
    else {
      const next=command(editor,line),note=next.performance.notes.find(n=>n.track===0)
      assert.deepEqual([note.start,note.duration],[250,300])
      assert.deepEqual(command(next,'undo').project,editor.project)
      assert.deepEqual(next.performance.diagnostics,editor.performance.diagnostics)
    }
  }
})
