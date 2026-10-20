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

test('MIDI revoicing retains source clocks, release dynamics and expressions through history and export', async () => {
  const file = new JZZ.MIDI.SMF(0, 1001), track = new JZZ.MIDI.SMF.MTrk()
  track.add(0, JZZ.MIDI.smfBPM(120)).add(0, JZZ.MIDI.smfMidiPort(3))
    .add(0, JZZ.MIDI.control(0, 1, 77)).add(0, JZZ.MIDI.pitchBend(0, 9000))
  for (const [i, key] of [60,64,67,71].entries()) track.add(0, JZZ.MIDI.noteOn(0, key, 80+i))
  track.add(0, JZZ.MIDI.noteOn(1, 36, 110)).add(1001, JZZ.MIDI.smfBPM(60))
  for (const [i, key] of [60,64,67,71].entries()) track.add(2002, JZZ.MIDI.noteOff(0, key, 30+i))
  track.add(3003, JZZ.MIDI.noteOff(1, 36, 50)).add(4004, JZZ.MIDI.smfEndOfTrack()); file.push(track)
  const bytes = file.toUint8Array(), source = importMidiSource(bytes), before = structuredClone(source)
  let editor = newEditor(source)
  assert.throws(() => editorCommand(editor, 'revoice Cmaj7 drop2'), /channel/)
  editor = editorCommand(editor, 'channel 1').editor
  const selected = selectedNote(editor).id
  editor = editorCommand(editor, 'revoice Cmaj7 drop2 4').editor
  assert.equal(selectedNote(editor).id, selected)
  const changed = editor.project, after = editor.performance
  const original = midiSourcePattern(source)
  for (const note of original.notes) {
    const next = after.notes.find(n => n.id === note.id)
    const { pitch, ...rest } = note, { pitch: nextPitch, ...nextRest } = next
    assert.deepEqual(nextRest, rest)
    if (note.channel === 1) assert.equal(nextPitch, pitch)
  }
  const noteEvents = new Set(original.notes.flatMap(note => [note.id, note.off]))
  assert.deepEqual(after.events.filter(e => !noteEvents.has(e.id)), original.events.filter(e => !noteEvents.has(e.id)))
  editor = editorAction(editor, { kind: 'undo' }); assert.deepEqual(editor.project, source)
  editor = editorAction(editor, { kind: 'redo' }); assert.deepEqual(editor.project, changed)
  const directory = await mkdtemp(join(tmpdir(), 'masc-midi-revoice-'))
  try {
    const path = join(directory, 'experiment.json')
    await saveProject(path, changed)
    const reopened = (await loadProject(path)).project
    const parsed = new JZZ.MIDI.SMF(projectMidi(reopened))
    assert.equal(parsed.ppqn, 1001)
    assert.deepEqual([...parsed[0]].filter(e => e.isNoteOn() && (e[0]&15) === 0).map(e => [e.tt,e[1],e[2]]),
      [[0,55,80],[0,60,81],[0,64,82],[0,71,83]])
    assert.deepEqual([...parsed[0]].filter(e => e.isNoteOff() && (e[0]&15) === 0).map(e => [e.tt,e[1],e[2]]),
      [[2002,55,30],[2002,60,31],[2002,64,32],[2002,71,33]])
  } finally { await rm(directory, { recursive: true, force: true }) }
  assert.deepEqual(source, before)
})

test('explicit source-note selection anchors revoicing when ports share a channel', () => {
  const file = new JZZ.MIDI.SMF(0,480), track = new JZZ.MIDI.SMF.MTrk()
  for (const port of [1,2]) {
    // An explicit different status after metadata avoids JZZ compressing a
    // running NoteOn status across that metadata boundary in the fixture.
    track.add(0,JZZ.MIDI.smfMidiPort(port)).add(0,JZZ.MIDI.control(0,1,port))
    for (const key of [60,64,67,71]) track.add(0,JZZ.MIDI.noteOn(0,key,90))
  }
  for (const port of [1,2]) {
    track.add(480,JZZ.MIDI.smfMidiPort(port)).add(480,JZZ.MIDI.control(0,1,port))
    for (const key of [60,64,67,71]) track.add(480,JZZ.MIDI.noteOff(0,key,45))
  }
  track.add(480,JZZ.MIDI.smfEndOfTrack());file.push(track)
  const source = importMidiSource(file.toUint8Array()), before = structuredClone(source)
  let editor = newEditor(source)
  assert.throws(() => editorCommand(editor, 'revoice Cmaj7 drop2'), /source ports/)
  const anchor = editor.performance.notes.find(n => n.port === 1)
  editor = editorCommand(editor, `select ${anchor.id}`).editor
  editor = editorCommand(editor, 'revoice Cmaj7 drop2').editor
  assert.deepEqual(editor.performance.notes.filter(n => n.port === 1).map(n => n.pitch), [55,60,64,71])
  assert.deepEqual(editor.performance.notes.filter(n => n.port === 2).map(n => n.pitch), [60,64,67,71])
  assert.deepEqual(source, before)
})

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

test('duplication retains original source ports while ordinary insertion uses its destination region',()=>{
  const file=new JZZ.MIDI.SMF(0,480),track=new JZZ.MIDI.SMF.MTrk()
  track.add(0,JZZ.MIDI.smfMidiPort(1)).add(0,JZZ.MIDI.noteOn(0,60,96))
    .add(30,JZZ.MIDI.noteOff(0,60)).add(120,JZZ.MIDI.smfMidiPort(2))
    .add(240,JZZ.MIDI.smfEndOfTrack());file.push(track)
  const source=importMidiSource(file.toUint8Array()),editor=newEditor(source),before=structuredClone(source)
  for(const offset of ['0.21875','0.3125']){
    assert.throws(()=>editorCommand(editor,`duplicate ${offset}`),/Duplicate changes the source port/)
    assert.deepEqual(editor.project,before)
    assert.equal(editor.undo.length,0)
  }
  const duplicated=editorCommand(editor,'duplicate 0.125').editor
  assert.deepEqual(midiSourcePattern(duplicated.project).notes.map(n=>[n.start,n.duration,n.port]),[[0,30,1],[60,30,1]])
  const inserted=editorCommand(editor,'note D4 0.3125 0.0625').editor
  assert.deepEqual(midiSourcePattern(inserted.project).notes.map(n=>[n.start,n.port]),[[0,1],[150,2]])
  assert.equal(midiSourcePattern(importMidiSource(projectMidi(duplicated.project))).notes[1].port,1)
})

test('endpoint zero-length notes remain selected through consecutive edits and history without extending the source',()=>{
  const file=new JZZ.MIDI.SMF(0,480),track=new JZZ.MIDI.SMF.MTrk()
  track.add(480,JZZ.MIDI.noteOn(0,60,96)).add(480,JZZ.MIDI.noteOff(0,60,45))
    .add(480,JZZ.MIDI.smfEndOfTrack());file.push(track)
  const source=importMidiSource(file.toUint8Array()),note=midiSourcePattern(source).notes[0]
  let editor=editorCommand(newEditor(source),`select ${note.id}`).editor
  for(const value of [100,101]){
    editor=editorAction(editor,{kind:'velocity',value})
    assert.equal(editor.tick,480)
    assert.equal(selectedNote(editor).id,note.id)
    assert.equal(selectedNote(editor).velocity,value)
  }
  editor=editorAction(editor,{kind:'undo'})
  assert.equal(selectedNote(editor).velocity,100)
  editor=editorAction(editor,{kind:'redo'})
  assert.equal(selectedNote(editor).velocity,101)
  assert.equal(midiSourcePattern(importMidiSource(projectMidi(editor.project))).ticks,480)
  assert.equal(editorView(editor).displayLength,480)
  assert.equal(editorView(editor).loop.end,480)
  editor=editorCommand(editor,'cursor 1 C4').editor
  assert.equal(selectedNote(editor).id,note.id)
  editor=editorAction(editor,{kind:'move',ticks:480})
  assert.equal(editor.tick,480)
  assert.throws(()=>editorCommand(editor,'cursor 2 C4'),/outside MIDI source/)
})
