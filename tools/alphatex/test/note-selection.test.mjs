import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { newEditor, editorCommand, editorAction, selectedNotes } from '../sequencer-editor.mjs'
import { projectMidi, saveProject, loadProject } from '../sequencer-files.mjs'
import { importMidiSource, midiSourcePattern } from '../midi-source.mjs'
import { PPQ } from '../sequencer-project.mjs'
midiFiles(JZZ)
const command = (editor, line) => editorCommand(editor, line).editor

test('select a phrase range, copy across tracks, vary its pitches, undo once, cut and save/reopen MIDI', async () => {
  let editor = newEditor()
  for (const line of ['note C4 1 1 70','note E4 2 2 99','note G4 4 1 80','select-notes 0 4 C4 E4','copy-notes']) editor = command(editor,line)
  const original = structuredClone(editor.project)
  assert.equal(selectedNotes(editor).length,2)
  assert.deepEqual(editor.project,original)
  editor = command(editor,'track-add Variation')
  assert.equal(selectedNotes(editor).length,0)
  editor = command(editor,'paste-notes 4 2')
  assert.deepEqual(editor.project.tracks[0],original.tracks[0])
  assert.deepEqual(selectedNotes(editor).map(note=>[note.pitch,note.start,note.duration,note.velocity]),[[62,5*PPQ,PPQ,70],[66,6*PPQ,2*PPQ,99]])
  const pasted = editor.project
  editor = editorAction(editor,{kind:'move-note',ticks:PPQ,pitches:-12})
  assert.deepEqual(selectedNotes(editor).map(note=>[note.pitch,note.start]),[[50,6*PPQ],[54,7*PPQ]])
  editor = command(editor,'undo');assert.deepEqual(editor.project,pasted);assert.equal(selectedNotes(editor).length,0)
  editor = command(editor,'select-all');editor = command(editor,'cut-notes')
  assert.equal(editor.project.tracks[1].notes.length,0)
  editor = command(editor,'paste-notes 0')
  assert.deepEqual(selectedNotes(editor).map(note=>note.start),[0,PPQ])
  const dir = await mkdtemp(join(tmpdir(),'masc-note-selection-'))
  try {
    const path=join(dir,'phrase.json');await saveProject(path,editor.project)
    const reopened=(await loadProject(path)).project;assert.deepEqual(reopened,editor.project)
    assert.equal('noteClipboard' in reopened,false)
    const file=new JZZ.MIDI.SMF(projectMidi(reopened))
    assert.deepEqual([...file[2]].filter(event=>event.isNoteOn()).map(event=>[event.tt,event.getNote()]),[[0,62],[PPQ,66]])
  } finally { await rm(dir,{recursive:true,force:true}) }
})

test('overlap, invalid range/register and source scope changes cannot partly edit or revive a selection', () => {
  let editor = newEditor()
  for(const line of ['note C4 0 2','note E4 2 1','select-all','copy-notes'])editor=command(editor,line)
  const before=structuredClone(editor)
  for(const line of ['paste-notes 0','paste-notes 15','move-notes -1 0','move-notes 0 100','select-notes 4 2','select-notes 0 4 C4','select-notes 0 4 E4 C4']){
    assert.throws(()=>command(editor,line));assert.deepEqual(editor,before)
  }
  assert.throws(()=>editorAction(editor,{kind:'toggle-note'}),/Clear/)
  editor=command(editor,'track-add Other');editor=command(editor,'track 1')
  assert.equal(selectedNotes(editor).length,0)
  editor=command(editor,'select-all');editor=editorAction(editor,{kind:'remove'})
  assert.equal(editor.project.tracks[0].notes.length,0)
  editor=command(editor,'undo');assert.deepEqual(editor.project.tracks[0],before.project.tracks[0])
})

function sourceFile(format=1, ppq=1001) {
  const file=new JZZ.MIDI.SMF(format,ppq), first=new JZZ.MIDI.SMF.MTrk()
  first.add(0,JZZ.MIDI.smfMidiPort(3)).add(0,JZZ.MIDI.smfBPM(90)).add(0,JZZ.MIDI.control(0,1,77))
    .add(0,JZZ.MIDI.noteOn(0,60,80)).add(ppq,JZZ.MIDI.noteOff(0,60,45))
    .add(ppq,JZZ.MIDI.noteOn(0,64,99)).add(ppq*2,JZZ.MIDI.noteOn(0,64,0))
    .add(ppq*2,JZZ.MIDI.noteOn(1,48,70)).add(ppq*3,JZZ.MIDI.noteOff(1,48,12))
    .add(ppq*8,JZZ.MIDI.smfEndOfTrack());file.push(first)
  file.push(new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.smfMidiPort(3)).add(0,JZZ.MIDI.control(4,7,90)).add(ppq*8,JZZ.MIDI.smfEndOfTrack()))
  return file.toUint8Array()
}
test('source note clipboard retains native ticks, both release forms/dynamics and unrelated expression through export', async () => {
  const source=importMidiSource(sourceFile()),before=structuredClone(source)
  let editor=newEditor(source)
  for(const line of ['channel 1','select-notes 0 2','copy-notes','track 2','channel 5','paste-notes 3 12'])editor=command(editor,line)
  assert.deepEqual(editor.project.original,source.original)
  const notes=selectedNotes(editor),events=new Map(editor.performance.events.map(event=>[event.id,event]))
  assert.deepEqual(notes.map(note=>[note.track,note.channel,note.port,note.start,note.duration,note.pitch,note.velocity]),[[1,4,3,3003,1001,72,80],[1,4,3,4004,1001,76,99]])
  assert.deepEqual(notes.map(note=>events.get(note.off).bytes),[[0x84,72,45],[0x94,76,0]])
  const originalEvents=midiSourcePattern(source).events.filter(event=>!(event.kind==='meta'&&event.type===0x2f))
  assert.deepEqual(editor.performance.events.filter(event=>!event.id.startsWith('new:')&&!(event.kind==='meta'&&event.type===0x2f)),originalEvents)
  const pasted=editor.project
  editor=command(editor,'undo');assert.deepEqual(editor.project,source)
  editor=command(editor,'redo');assert.deepEqual(editor.project,pasted)
  assert.equal(selectedNotes(editor).length,0)
  const dir=await mkdtemp(join(tmpdir(),'masc-source-selection-'))
  try{
    const path=join(dir,'source.json');await saveProject(path,pasted)
    const reopened=(await loadProject(path)).project
    const exported=midiSourcePattern(importMidiSource(projectMidi(reopened)))
    const trackNotes=exported.notes.filter(note=>note.track===1)
    const outputEvents=new Map(exported.events.map(event=>[event.id,event]))
    assert.deepEqual(trackNotes.map(note=>[note.start,outputEvents.get(note.off).bytes]),[[3003,[0x84,72,45]],[4004,[0x94,76,0]]])
  }finally{await rm(dir,{recursive:true,force:true})}
  assert.deepEqual(source,before)
})

test('source selection follows channel/pattern context and refuses pasted routing changes transactionally', () => {
  const file=new JZZ.MIDI.SMF(sourceFile(2)),track=file[1]
  track.add(4004,JZZ.MIDI.smfMidiPort(5))
  let editor=newEditor(importMidiSource(file.toUint8Array()),{pattern:0})
  for(const line of ['channel 1','select-all','copy-notes','pattern 2'])editor=command(editor,line)
  assert.equal(selectedNotes(editor).length,0)
  const before=structuredClone(editor)
  assert.throws(()=>command(editor,'paste-notes 4'),/source port/)
  assert.deepEqual(editor,before)
  editor=command(editor,'paste-notes 0')
  assert.equal(selectedNotes(editor).length,2)
  editor=command(editor,'channel 2');editor=command(editor,'channel 1')
  assert.equal(selectedNotes(editor).length,0)
})

test('SMPTE selection keyboard movement uses raw integer source ticks and point notes survive copy/paste', () => {
  const file=new JZZ.MIDI.SMF(0,80),track=new JZZ.MIDI.SMF.MTrk()
  track.add(0,JZZ.MIDI.noteOn(0,60,80)).add(0,JZZ.MIDI.noteOff(0,60,23)).add(400,JZZ.MIDI.smfEndOfTrack());file.push(track)
  const bytes=Buffer.from(file.toUint8Array());bytes.writeUInt16BE(0xe350,12)
  let editor=newEditor(importMidiSource(bytes))
  editor=command(editor,'select-all');editor=command(editor,'copy-notes');editor=command(editor,'paste-notes 1')
  assert.deepEqual(selectedNotes(editor).map(note=>[note.start,note.duration]),[[80,0]])
  editor=editorAction(editor,{kind:'move-note',ticks:1,pitches:2})
  assert.deepEqual(selectedNotes(editor).map(note=>[note.start,note.duration,note.pitch]),[[81,0,62]])
  assert.deepEqual(editor.axis,{per:80,label:'frames'})
})
