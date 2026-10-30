import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { newEditor, editorCommand, editorAction, selectedNote, editorView } from '../sequencer-editor.mjs'
import { loadProject, saveProject, projectMidi } from '../sequencer-files.mjs'
import { importMidiSource, midiSourcePattern } from '../midi-source.mjs'
import { PPQ } from '../sequencer-project.mjs'
midiFiles(JZZ)

test('reopening a bass phrase starts at its first note and preserves later manual cursor edits', async () => {
  let editor = newEditor()
  assert.deepEqual([editor.track, editor.tick, editor.pitch], [0, 0, 60])
  for (const line of ['track-add Bass', 'note D2 6 1', 'note C2 4 1', 'program 33']) {
    editor = editorCommand(editor, line).editor
  }
  const directory = await mkdtemp(join(tmpdir(), 'masc-phrase-entry-'))
  try {
    const path = join(directory, 'bass.json')
    await saveProject(path, editor.project)
    const loaded = await loadProject(path)
    editor = newEditor(loaded.project)
    assert.equal(editor.project, loaded.project)
    assert.deepEqual([editor.track, editor.tick, editor.pitch], [1, 4 * PPQ, 36])
    const selected = selectedNote(editor)
    assert.equal(selected.pitch, 36)
    editor = editorAction(editor, { kind: 'velocity', value: 112 })
    assert.equal(selectedNote(editor).id, selected.id)
    assert.equal(selectedNote(editor).velocity, 112)
    editor = editorCommand(editor, 'cursor 10 G3').editor
    editor = editorCommand(editor, 'rename Retained bass').editor
    editor = editorAction(editor, { kind: 'undo' })
    assert.deepEqual([editor.tick, editor.pitch], [10 * PPQ, 55])
    assert.equal(loaded.project.tracks[1].notes.find(note => note.id === selected.id).velocity, 96)
  } finally { await rm(directory, { recursive: true, force: true }) }
})

test('imported MIDI skips a conductor track, opens its low note and keeps manual position after edits', () => {
  const file = new JZZ.MIDI.SMF(1, 480)
  file.push(new JZZ.MIDI.SMF.MTrk().add(0, JZZ.MIDI.smfBPM(120)).add(1920, JZZ.MIDI.smfEndOfTrack()))
  file.push(new JZZ.MIDI.SMF.MTrk().add(960, JZZ.MIDI.noteOn(2, 36, 90))
    .add(1440, JZZ.MIDI.noteOff(2, 36)).add(1920, JZZ.MIDI.smfEndOfTrack()))
  const source = importMidiSource(file.toUint8Array())
  let editor = newEditor(source)
  assert.equal(editor.project, source)
  assert.deepEqual([editor.track, editor.tick, editor.pitch], [1, 960, 36])
  assert.equal(selectedNote(editor).channel, 2)
  editor = editorCommand(editor, 'cursor 0 C4').editor
  editor = editorCommand(editor, 'cc 1 80').editor
  assert.deepEqual([editor.track, editor.tick, editor.pitch], [1, 0, 60])
  assert.equal(midiSourcePattern(importMidiSource(projectMidi(editor.project))).notes[0].pitch, 36)
  assert.equal(midiSourcePattern(source).events.some(event => event.kind === 'channel' && event.bytes[0] === 0xb2), false)
})

test('explicit format-2 pattern choice finds its own high note without choosing ambiguous channels', () => {
  const file = new JZZ.MIDI.SMF(2, 480)
  file.push(new JZZ.MIDI.SMF.MTrk().add(0, JZZ.MIDI.noteOn(0, 36, 90))
    .add(480, JZZ.MIDI.noteOff(0, 36)).add(960, JZZ.MIDI.smfEndOfTrack()))
  file.push(new JZZ.MIDI.SMF.MTrk().add(480, JZZ.MIDI.noteOn(1, 91, 90))
    .add(960, JZZ.MIDI.noteOff(1, 91)).add(960, JZZ.MIDI.smfEndOfTrack()))
  let editor = newEditor(importMidiSource(file.toUint8Array()))
  assert.equal(editor.performance, null)
  editor = editorCommand(editor, 'pattern 2').editor
  assert.deepEqual([editor.tick, editor.pitch, selectedNote(editor).channel], [480, 91, 1])
  editor = editorCommand(editor, 'pattern 1').editor
  assert.deepEqual([editor.tick, editor.pitch], [0, 36])
  assert.equal(editorView(editor).tracks[0].sourceTrack, 0)
  const ambiguous = new JZZ.MIDI.SMF(0, 480)
  ambiguous.push(new JZZ.MIDI.SMF.MTrk().add(480, JZZ.MIDI.noteOn(0, 36, 90))
    .add(480, JZZ.MIDI.noteOn(1, 36, 80)).add(960, JZZ.MIDI.noteOff(0, 36))
    .add(960, JZZ.MIDI.noteOff(1, 36)).add(960, JZZ.MIDI.smfEndOfTrack()))
  editor = newEditor(importMidiSource(ambiguous.toUint8Array()))
  assert.deepEqual([editor.tick, editor.pitch], [480, 36])
  assert.equal(editor.channel, undefined)
  assert.equal(selectedNote(editor), undefined)
  assert.throws(() => editorAction(editor, { kind: 'toggle-note' }), /Several source notes/)
})
