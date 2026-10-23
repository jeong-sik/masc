import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { newEditor, editorCommand, selectedNotes } from '../sequencer-editor.mjs'
import { importMidiSource, midiSourcePattern } from '../midi-source.mjs'
import { saveProject, loadProject, projectMidi } from '../sequencer-files.mjs'
midiFiles(JZZ)
const command = (editor, line) => editorCommand(editor, line).editor
const commands = (editor, lines) => lines.reduce(command, editor)

function sourceBytes({ smpte = false, portChange = false, point = false } = {}) {
  const file = new JZZ.MIDI.SMF(1, smpte ? 80 : 1000), first = new JZZ.MIDI.SMF.MTrk()
  first.add(0, JZZ.MIDI.smfMidiPort(portChange ? 1 : 3)).add(0, JZZ.MIDI.smfBPM(90))
    .add(0, JZZ.MIDI.control(0, 1, 77))
  if (portChange) first.add(100, JZZ.MIDI.smfMidiPort(3))
  first.add(130, JZZ.MIDI.noteOn(0, 60, 80)).add(430, JZZ.MIDI.noteOff(0, 60, 45))
    .add(760, JZZ.MIDI.noteOn(0, 64, 99)).add(1010, JZZ.MIDI.noteOn(0, 64, 0))
    .add(1250, JZZ.MIDI.noteOn(1, 48, 70)).add(1500, JZZ.MIDI.noteOff(1, 48, 12))

  if (point) first.add(1700, JZZ.MIDI.noteOn(0, 67, 88)).add(1700, JZZ.MIDI.noteOff(0, 67, 23))
  first.add(4000, JZZ.MIDI.smfEndOfTrack())
  file.push(first)
  file.push(new JZZ.MIDI.SMF.MTrk().add(0, JZZ.MIDI.noteOn(4, 72, 55))
    .add(1000, JZZ.MIDI.noteOff(4, 72, 9)).add(4000, JZZ.MIDI.smfEndOfTrack()))
  const bytes = Buffer.from(file.toUint8Array())
  if (smpte) bytes.writeUInt16BE(0xe350, 12)
  return bytes
}

test('phrase selected quantize preserves other tracks, lengths and dynamics and is one undoable save/export transaction', async () => {
  let editor = commands(newEditor(), ['note C4 0.125 0.25 70', 'note E4 0.8 0.5 99',
    'note G4 3 1 80', 'track-add Other', 'note C3 0.3 2 50', 'track 1', 'select-notes 0.1 1'])
  const before = structuredClone(editor), oldHistory = editor.undo.length
  editor = command(editor, 'quantize-notes 0.25')
  assert.deepEqual(selectedNotes(editor).map(n => [n.start, n.duration, n.velocity]), [[240, 240, 70], [720, 480, 99]])
  assert.deepEqual(editor.project.tracks[1], before.project.tracks[1])
  assert.deepEqual(editor.project.tracks[0].notes.find(n => n.pitch === 67), before.project.tracks[0].notes.find(n => n.pitch === 67))
  assert.equal(editor.noteSelection.origin, 0)
  assert.equal(editor.undo.length, oldHistory + 1)
  const edited = editor.project
  editor = command(editor, 'undo'); assert.deepEqual(editor.project, before.project)
  editor = command(editor, 'redo'); assert.deepEqual(editor.project, edited)
  const directory = await mkdtemp(join(tmpdir(), 'masc-selected-quantize-'))
  try {
    const path = join(directory, 'phrase.json'); await saveProject(path, edited)
    const saved = (await loadProject(path)).project
    assert.deepEqual(saved, edited)
    const track = new JZZ.MIDI.SMF(projectMidi(saved))[1]
    assert.deepEqual([...track].filter(e => e.isNoteOn()).map(e => [e.tt, e.getVelocity()]), [[240, 70], [720, 99], [2880, 80]])
  } finally { await rm(directory, { recursive: true, force: true }) }
})

test('PPQ selected quantize preserves source clock, release forms, other channels and expression through MIDI export', () => {
  const source = importMidiSource(sourceBytes())
  let editor = commands(newEditor(source), ['channel 1', 'select-notes 0 1'])
  const before = structuredClone(editor)
  editor = command(editor, 'quantize-notes 0.25')
  assert.deepEqual(selectedNotes(editor).map(n => [n.start, n.duration, n.velocity, n.port]), [[250, 300, 80, 3], [750, 250, 99, 3]])
  assert.deepEqual(editor.project.original, source.original)
  const unchanged = events => events.filter(e => e.kind !== 'channel' || ![0x80, 0x90].includes(e.bytes[0]))
  assert.deepEqual(unchanged(editor.performance.events), unchanged(before.performance.events))
  const exported = midiSourcePattern(importMidiSource(projectMidi(editor.project)))
  const rows = exported.notes.filter(n => n.track === 0 && n.channel === 0)
  const events = new Map(exported.events.map(e => [e.id, e]))
  assert.deepEqual(rows.map(n => [n.start, n.duration, events.get(n.off).bytes]), [[250, 300, [0x80, 60, 45]], [750, 250, [0x90, 64, 0]]])
  assert.deepEqual(command(editor, 'undo').project, before.project)
})

test('quantize refuses new same-key source overlaps but preserves a source overlap that was already present', () => {
  const source = rows => {
    const file = new JZZ.MIDI.SMF(0, 1000), track = new JZZ.MIDI.SMF.MTrk()
    for (const [start, duration] of rows) track.add(start, JZZ.MIDI.noteOn(0, 60, 80))
      .add(start + duration, JZZ.MIDI.noteOff(0, 60, 45))
    file.push(track.add(2000, JZZ.MIDI.smfEndOfTrack()))
    return newEditor(importMidiSource(file.toUint8Array()))
  }
  for (const rows of [[[140, 100], [360, 300]], [[140, 0], [160, 0]]]) {
    const editor = command(source(rows), 'select-all'), before = structuredClone(editor)
    assert.throws(() => command(editor, 'quantize-notes 0.25'), /overlapping/)
    assert.deepEqual(editor, before)
  }
  const partial = command(source([[140, 200], [360, 300]]), 'select-notes 0 0.25')
  assert.throws(() => command(partial, 'quantize-notes 0.25'), /overlapping/)
  const existing = command(source([[140, 300], [360, 300]]), 'select-all')
  const preserved = command(existing, 'quantize-notes 0.25')
  assert.deepEqual(selectedNotes(preserved).map(n => [n.start, n.duration]), [[250, 300], [250, 300]])
  assert.deepEqual(command(preserved, 'undo').project, existing.project)
})

test('source quantize also checks other tracks sharing its MIDI destination, while distinct routes stay independent', () => {
  for (const [port, channel] of [[0, 0], [1, 0], [0, 1]]) {
    const file = new JZZ.MIDI.SMF(1, 1000)
    file.push(new JZZ.MIDI.SMF.MTrk().add(140, JZZ.MIDI.noteOn(0, 60, 80))
      .add(340, JZZ.MIDI.noteOff(0, 60, 45)).add(2000, JZZ.MIDI.smfEndOfTrack()))
    file.push(new JZZ.MIDI.SMF.MTrk().add(0, JZZ.MIDI.smfMidiPort(port))
      .add(360, JZZ.MIDI.noteOn(channel, 60, 70)).add(660, JZZ.MIDI.noteOff(channel, 60, 23))
      .add(2000, JZZ.MIDI.smfEndOfTrack()))
    const editor = command(newEditor(importMidiSource(file.toUint8Array())), 'select-all')
    const before = structuredClone(editor)
    if (port === 0 && channel === 0) {
      assert.throws(() => command(editor, 'quantize-notes 0.25'), /overlapping/)
      assert.deepEqual(editor, before)
    } else {
      const changed = command(editor, 'quantize-notes 0.25')
      assert.equal(selectedNotes(changed)[0].start, 250)
      const native = notes => notes.map(({ seconds, durationSeconds, ...note }) => note)
      assert.deepEqual(native(changed.view.tracks[1].notes), native(editor.view.tracks[1].notes))
    }
  }
})

test('SMPTE selection uses frame grid and retains point notes', () => {
  let editor = newEditor(importMidiSource(sourceBytes({ smpte: true, point: true })))
  editor = commands(editor, ['channel 1', 'select-all', 'quantize-notes 1'])
  assert.deepEqual(selectedNotes(editor).map(n => [n.start, n.duration]), [[160, 300], [800, 250], [1680, 0]])
  assert.deepEqual(editor.axis, { per: 80, label: 'frames' })
})

test('selected quantize refuses invalid grids, collisions and source port changes without a partial edit', () => {
  const editor = commands(newEditor(), ['note C4 0.1 0.1', 'note C4 0.4 0.1', 'select-all'])
  const before = structuredClone(editor)
  for (const line of ['quantize-notes 0', 'quantize-notes -1', 'quantize-notes NaN', 'quantize-notes Infinity',
    'quantize-notes 0.0001', 'quantize-notes 1', 'quantize-notes 0.25 extra']) {
    assert.throws(() => command(editor, line)); assert.deepEqual(editor, before)
  }
  assert.throws(() => command(newEditor(), 'quantize-notes 1'), /Select notes/)
  const routed = commands(newEditor(importMidiSource(sourceBytes({ portChange: true }))), ['channel 1', 'select-notes 0 0.5'])
  const original = structuredClone(routed)
  assert.throws(() => command(routed, 'quantize-notes 1'), /source port/)
  assert.deepEqual(routed, original)
})
