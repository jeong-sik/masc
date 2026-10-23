import test from 'node:test'
import assert from 'node:assert/strict'
import {mkdtemp,rm} from 'node:fs/promises'
import {tmpdir} from 'node:os'
import {join} from 'node:path'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import {newEditor,editorCommand,selectedNotes} from '../sequencer-editor.mjs'
import {importMidiSource,midiSourcePattern} from '../midi-source.mjs'
import {loadProject,saveProject,projectMidi} from '../sequencer-files.mjs'
midiFiles(JZZ)
const command=(editor,line)=>editorCommand(editor,line).editor
const commands=(editor,lines)=>lines.reduce(command,editor)
const native=events=>events.map(({seconds,durationSeconds,...event})=>event)
function source({smpte=false,point=false,portChange=false,type=1}={}) {
  const file=smpte?new JZZ.MIDI.SMF(type,29,80):new JZZ.MIDI.SMF(type,1001)
  const track=new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.smfMidiPort(3))
    .add(0,JZZ.MIDI.control(0,1,77)).add(0,JZZ.MIDI.smfBPM(120))
    .add(143,JZZ.MIDI.noteOn(0,60,80)).add(point?143:429,JZZ.MIDI.noteOff(0,60,45))
    .add(1001,JZZ.MIDI.noteOn(0,64,99)).add(1287,JZZ.MIDI.noteOn(0,64,0))
    .add(2002,JZZ.MIDI.noteOn(1,48,70)).add(3003,JZZ.MIDI.noteOff(1,48,12))
    .add(500,JZZ.MIDI.pitchBend(0,9000))
  if(portChange)track.add(600,JZZ.MIDI.smfMidiPort(7))
  file.push(track.add(6006,JZZ.MIDI.smfEndOfTrack()))
  file.push(new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.noteOn(4,72,55))
    .add(1001,JZZ.MIDI.noteOff(4,72,9)).add(6006,JZZ.MIDI.smfEndOfTrack()))
  return importMidiSource(file.toUint8Array())
}

test('phrase stretch changes selected spacing and gates about a stable origin in one undo, with save/export',async()=>{
  const editor=commands(newEditor(),['note C4 2 0.5 70','note E4 3 1 99','note G4 8 1 80',
    'track-add Bass','note C2 0 2 50','track 1','select-notes 2 4','copy-notes'])
  const before=structuredClone(editor),next=command(editor,'stretch-notes 2')
  assert.deepEqual(selectedNotes(next).map(n=>[n.start,n.duration,n.velocity]),[[1920,960,70],[3840,1920,99]])
  assert.deepEqual(next.noteSelection,editor.noteSelection);assert.deepEqual(next.noteClipboard,editor.noteClipboard)
  assert.deepEqual(next.project.tracks[1],editor.project.tracks[1]);assert.deepEqual(next.project.tracks[0].notes[2],editor.project.tracks[0].notes[2])
  assert.equal(next.undo.length,editor.undo.length+1)
  assert.deepEqual(command(next,'undo').project,editor.project)
  assert.deepEqual(command(command(next,'undo'),'redo').project,next.project)
  assert.deepEqual(command(next,'stretch-notes 1/2').project,editor.project)
  assert.deepEqual(editor,before)
  const anchored=command(editor,'stretch-notes .5 1')
  assert.equal(anchored.noteSelection.origin,1440)
  assert.deepEqual(selectedNotes(anchored).map(n=>[n.start,n.duration]),[[1440,240],[1920,480]])
  const directory=await mkdtemp(join(tmpdir(),'masc-stretch-'))
  try {
    const path=join(directory,'phrase.json');await saveProject(path,next.project)
    const reopened=(await loadProject(path)).project;assert.deepEqual(reopened,next.project)
    const exported=midiSourcePattern(importMidiSource(projectMidi(reopened)))
    assert.deepEqual(exported.notes.filter(n=>n.track===1).map(n=>[n.start,n.duration,n.velocity]),
      [[1920,960,70],[3840,1920,99],[7680,960,80]])
  }finally{await rm(directory,{recursive:true,force:true})}
})

for(const smpte of [false,true])for(const type of [1,2])test(`${smpte?'SMPTE':'PPQ1001'} SMF${type} stretch preserves raw source and all unrelated events`,()=>{
  const original=source({smpte,type}),editor=commands(newEditor(original,{pattern:type===2?0:undefined}),['channel 1','select-all','copy-notes'])
  const before=structuredClone(editor),next=command(editor,'stretch-notes 2')
  assert.deepEqual(selectedNotes(next).map(n=>[n.start,n.duration,n.velocity]),[[143,572,80],[1859,572,99]])
  const changed=new Set(selectedNotes(editor).flatMap(n=>[n.id,n.off]))
  assert.deepEqual(native(next.performance.events.filter(e=>!changed.has(e.id))),native(editor.performance.events.filter(e=>!changed.has(e.id))))
  assert.deepEqual(selectedNotes(next).map(n=>[n.id,n.off,n.port,n.channel]),selectedNotes(editor).map(n=>[n.id,n.off,n.port,n.channel]))
  assert.deepEqual(next.noteSelection,editor.noteSelection);assert.deepEqual(next.noteClipboard,editor.noteClipboard)
  const exported=midiSourcePattern(importMidiSource(projectMidi(next.project)),{pattern:type===2?0:undefined}),events=new Map(exported.events.map(e=>[e.id,e]))
  assert.deepEqual(exported.notes.filter(n=>n.track===0&&n.channel===0).map(n=>[n.start,n.duration,events.get(n.off).bytes]),
    [[143,572,[0x80,60,45]],[1859,572,[0x90,64,0]]])
  assert.deepEqual(exported.timing,editor.performance.timing);assert.equal(next.project.original,original.original)
  if(type===2)assert.deepEqual(midiSourcePattern(importMidiSource(projectMidi(next.project)),{pattern:1}),
    midiSourcePattern(original,{pattern:1}))
  assert.equal(next.undo.length,editor.undo.length+1);assert.deepEqual(command(next,'undo').project,editor.project)
  assert.deepEqual(command(command(next,'undo'),'redo').project,next.project)
  assert.deepEqual(selectedNotes(command(next,'stretch-notes 1/2')),selectedNotes(editor))
  assert.deepEqual(editor,before)
})

test('source point notes remain points; ratio and native-tick exactness are still required',()=>{
  const editor=commands(newEditor(source({point:true})),['channel 1','select-all'])
  const next=command(editor,'stretch-notes 1/2')
  assert.deepEqual(selectedNotes(next).map(n=>[n.start,n.duration]),[[143,0],[572,143]])
  for(const factor of ['0','-1','NaN','1e2','0x2','1/0','1/7']) {
    const before=structuredClone(editor);assert.throws(()=>command(editor,'stretch-notes '+factor));assert.deepEqual(editor,before)
  }
})

test('invalid ratios, positions, document bounds and port transitions reject the whole editor transaction',()=>{
  const editors=[commands(newEditor(),['note C4 15 1','select-all','copy-notes']),commands(newEditor(source()),['channel 1','select-all','copy-notes'])]
  for(const editor of editors) {
    const before=structuredClone(editor)
    for(const line of ['stretch-notes','stretch-notes 2 0 extra','stretch-notes 0','stretch-notes -1','stretch-notes Infinity',
      'stretch-notes 1/0','stretch-notes 1.5/2','stretch-notes 1e1','stretch-notes 0x2','stretch-notes 1/17',
      'stretch-notes 9007199254740991','stretch-notes 2 -1','stretch-notes 2 0.000001','stretch-notes 2 100']) {
      assert.throws(()=>command(editor,line),line);assert.deepEqual(editor,before)
    }
  }
  const phrase=editors[0],snapshot=structuredClone(phrase)
  assert.throws(()=>command(phrase,'stretch-notes 2'));assert.deepEqual(phrase,snapshot)
  const routed=commands(newEditor(source({portChange:true})),['channel 1','select-notes 1/7 2/7']),before=structuredClone(routed)
  assert.throws(()=>command(routed,'stretch-notes 2'),/source port/);assert.deepEqual(routed,before)
  assert.throws(()=>command(newEditor(),'stretch-notes 2'),/Select notes/)
})

test('stretch refuses new same-route overlaps and retains existing same-tick release/attack order',()=>{
  const phrase=commands(newEditor(),['note C4 0.5 0.25','note C4 1 0.25','select-notes 0.5 0.75'])
  const before=structuredClone(phrase);assert.throws(()=>command(phrase,'stretch-notes 4'),/overlapping/);assert.deepEqual(phrase,before)
  for(const mode of ['paired','unclosed']) {
    const file=new JZZ.MIDI.SMF(0,1000),track=new JZZ.MIDI.SMF.MTrk()
      .add(0,JZZ.MIDI.noteOn(0,60,80)).add(200,JZZ.MIDI.noteOff(0,60,45)).add(300,JZZ.MIDI.noteOn(0,60,77))
    if(mode==='paired')track.add(400,JZZ.MIDI.noteOff(0,60,12))
    file.push(track.add(2000,JZZ.MIDI.smfEndOfTrack()))
    const editor=command(newEditor(importMidiSource(file.toUint8Array())),'select-notes 0 0.1'),snapshot=structuredClone(editor)
    assert.throws(()=>command(editor,'stretch-notes 2'),/overlapping/);assert.deepEqual(editor,snapshot)
  }
  const file=new JZZ.MIDI.SMF(0,1000),track=new JZZ.MIDI.SMF.MTrk()
    .add(100,JZZ.MIDI.noteOn(0,60,80)).add(100,JZZ.MIDI.noteOff(0,60,45))
    .add(100,JZZ.MIDI.noteOn(0,60,70)).add(100,JZZ.MIDI.noteOff(0,60,12)).add(2000,JZZ.MIDI.smfEndOfTrack())
  file.push(track)
  const editor=command(newEditor(importMidiSource(file.toUint8Array())),'select-all')
  const next=command(editor,'stretch-notes 2 0')
  assert.deepEqual(selectedNotes(next).map(n=>[n.start,n.duration]),[[200,0],[200,0]])
  assert.deepEqual(next.performance.events.filter(e=>e.tick===200).map(e=>e.bytes),editor.performance.events.filter(e=>e.tick===100).map(e=>e.bytes))
})
