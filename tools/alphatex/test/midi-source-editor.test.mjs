import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { importMidiSource, midiSourcePattern } from '../midi-source.mjs'
import { newEditor, editorCommand, editorAction, editorView, editorAxis, editorHarmony, selectedNote } from '../sequencer-editor.mjs'
import { saveProject, loadProject, projectMidi } from '../sequencer-files.mjs'
midiFiles(JZZ)
function performance(format=1, division=1001) {
  const file=new JZZ.MIDI.SMF(format,division)
  const track=new JZZ.MIDI.SMF.MTrk()
  track.add(0,JZZ.MIDI.smfBPM(120)).add(0,JZZ.MIDI.smfSeqName('Expressive piano'))
    .add(0,JZZ.MIDI.control(0,1,77)).add(0,JZZ.MIDI.pitchBend(0,9000))
    .add(0,JZZ.MIDI.noteOn(0,60,96)).add(division,JZZ.MIDI.noteOff(0,60,45))
    .add(division,JZZ.MIDI.smfBPM(60)).add(division*4,JZZ.MIDI.smfEndOfTrack())
  file.push(track)
  if(format===2)file.push(new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.noteOn(1,67,90)).add(division,JZZ.MIDI.noteOff(1,67)).add(division,JZZ.MIDI.smfEndOfTrack()))
  return file.toUint8Array()
}

test('imported performance supports chord experiments, note decisions, undo, save/reopen and full-data export', async()=>{
  const bytes=performance(),source=importMidiSource(bytes)
  let editor=newEditor(source)
  assert.equal(editorAxis(editor).per,1001)
  assert.equal(editor.step,1001)
  assert.equal(selectedNote(editor).pitch,60)
  editor=editorAction(editor,{kind:'move-note',pitches:2})
  assert.equal(selectedNote(editor).pitch,62)
  editor=editorAction(editor,{kind:'duration',value:2002})
  editor=editorAction(editor,{kind:'velocity',value:111})
  editor=editorCommand(editor,'chord Em7 2 1 close').editor
  assert.equal(editorView(editor).tracks[0].notes.length,5)
  editor=editorAction(editor,{kind:'undo'});assert.equal(editorView(editor).tracks[0].notes.length,1)
  editor=editorAction(editor,{kind:'redo'});assert.equal(editorView(editor).tracks[0].notes.length,5)
  editor=editorCommand(editor,'cursor 2 E4').editor
  assert.ok(editorHarmony(editor).candidates.includes('Em7'))
  const directory=await mkdtemp(join(tmpdir(),'masc-midi-edit-workflow-'))
  try{
    const original=join(directory,'performance.mid'),path=join(directory,'experiment.json')
    await writeFile(original,bytes)
    const revision=await saveProject(path,editor.project)
    const loaded=await loadProject(path)
    assert.equal(loaded.revision,revision)
    const output=projectMidi(loaded.project),parsed=new JZZ.MIDI.SMF(output)
    assert.equal(parsed.ppqn,1001)
    assert.ok([...parsed[0]].some(e=>e[0]===0xb0&&e[1]===1&&e[2]===77))
    assert.ok([...parsed[0]].some(e=>e[0]===0xe0))
    assert.equal([...parsed[0]].filter(e=>e.isTempo()).length,2)
    assert.equal(midiSourcePattern(loaded.project).notes[0].velocity,111)
    assert.deepEqual(await readFile(original),Buffer.from(bytes))
    assert.equal(midiSourcePattern(source).notes.length,1)
    assert.equal(editorView(newEditor(loaded.project)).tracks[0].notes.length,5)
  }finally{await rm(directory,{recursive:true,force:true})}
})

test('format-2 selection and ambiguous-channel note selection require explicit decisions',()=>{
  let editor=newEditor(importMidiSource(performance(2,480)))
  assert.equal(editor.performance,null)
  assert.throws(()=>editorCommand(editor,'note C4 0 1'),/channel|pattern/)
  editor=editorCommand(editor,'pattern 2').editor
  assert.deepEqual(editorView(editor).tracks[0].notes.map(n=>n.pitch),[67])
  assert.throws(()=>newEditor(editor.project,{pattern:9}),/pattern/)
  const file=new JZZ.MIDI.SMF(0,480),track=new JZZ.MIDI.SMF.MTrk()
  track.add(0,JZZ.MIDI.noteOn(0,60,96)).add(0,JZZ.MIDI.noteOn(1,60,80))
    .add(480,JZZ.MIDI.noteOff(0,60)).add(480,JZZ.MIDI.noteOff(1,60)).add(480,JZZ.MIDI.smfEndOfTrack());file.push(track)
  editor=newEditor(importMidiSource(file.toUint8Array()))
  assert.equal(selectedNote(editor),undefined)
  assert.throws(()=>editorAction(editor,{kind:'toggle-note'}),/Several source notes/)
  editor=editorCommand(editor,'channel 2').editor
  assert.equal(selectedNote(editor).channel,1)
  editor=editorAction(editor,{kind:'move-note',pitches:1})
  assert.equal(selectedNote(editor).pitch,61)
  assert.equal(editorView(editor).tracks[0].notes.find(n=>n.channel===0).pitch,60)
})
