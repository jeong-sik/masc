import test from 'node:test'
import assert from 'node:assert/strict'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { tickUnits } from '../tick-units.mjs'
import { newEditor, editorCommand } from '../sequencer-editor.mjs'
import { stepControl } from '../step-input.mjs'
import { importMidiSource, midiSourcePattern } from '../midi-source.mjs'
import { projectMidi } from '../sequencer-files.mjs'
import { arrangementEditor, arrangementCommand } from '../arrangement-editor.mjs'
midiFiles(JZZ)
const command = (editor, text) => editorCommand(editor, text).editor

test('decimal onsets and triplet lengths survive phrase editing and real MIDI export', () => {
  let editor = command(newEditor(), 'note C4 8.3 1/3 91')
  assert.deepEqual(editor.project.tracks[0].notes.map(n => [n.start,n.duration,n.velocity]), [[7968,320,91]])
  const before = editor.project
  editor = command(editor, 'select-notes 8.3 9')
  editor = command(editor, 'move-notes -1/3 0')
  assert.equal(editor.project.tracks[0].notes[0].start, 7648)
  const exported = midiSourcePattern(importMidiSource(projectMidi(editor.project)))
  assert.deepEqual(exported.notes.map(n => [n.start,n.duration,n.pitch,n.velocity]), [[7648,320,60,91]])
  editor = command(editor, 'undo'); assert.deepEqual(editor.project, before)
  assert.equal(stepControl(newEditor(), { kind: 'step-rest', value: '8.3' }).tick, 7968)
})

test('imported PPQ and SMPTE use their own exact units and retain controller/release bytes', () => {
  for (const smpte of [false,true]) {
    const file = smpte ? new JZZ.MIDI.SMF(1,25,80) : new JZZ.MIDI.SMF(1,1001)
    file.push(new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.control(4,1,77))
      .add(0,JZZ.MIDI.noteOn(4,60,70)).add(1001,JZZ.MIDI.noteOff(4,60,45)).add(20020,JZZ.MIDI.smfEndOfTrack()))
    let editor = newEditor(importMidiSource(file.toUint8Array()))
    const original = editor.project, controller = editor.performance.events.find(e => e.bytes?.[0] === 0xb4)
    editor = command(editor, smpte ? 'note D4 8.3 1/5 91' : 'note D4 1/7 1/7 91')
    const expected = smpte ? [664,16] : [143,143]
    assert.deepEqual(editor.performance.notes.find(n => n.pitch === 62).start, expected[0])
    const exported = midiSourcePattern(importMidiSource(projectMidi(editor.project)))
    assert.deepEqual(exported.notes.find(n => n.pitch === 62).duration, expected[1])
    assert.deepEqual(exported.events.find(e => e.bytes?.[0] === 0xb4).bytes, controller.bytes)
    assert.ok(exported.events.some(e => e.bytes?.join() === '132,60,45'))
    editor = command(editor, 'undo'); assert.deepEqual(editor.project, original)
    const before = structuredClone(editor)
    assert.throws(() => command(editor, smpte ? 'note D4 1/3 1 91' : 'note D4 8.3 1 91'))
    assert.deepEqual(editor, before)
  }
})

test('arrangement cursor, grid and loop share exact phrase beats without changing source data', () => {
  let editor = arrangementEditor()
  editor = arrangementCommand(editor, 'cursor 8.3').editor
  assert.equal(editor.tick, 7968)
  editor = arrangementCommand(editor, 'grid 1/3').editor
  assert.equal(editor.step, 320)
  const before = structuredClone(editor)
  assert.throws(() => arrangementCommand(editor, 'cursor 8.300000000000000001'))
  assert.deepEqual(editor, before)
})

test('authored precision cannot round a fractional or unsafe tick into an admissible integer', () => {
  assert.equal(tickUnits('9007199254740991',1), Number.MAX_SAFE_INTEGER)
  assert.equal(tickUnits('-9007199254740991',1,{signed:true}), -Number.MAX_SAFE_INTEGER)
  assert.equal(tickUnits('.5',960),480)
  for (const value of ['0.999999999999999999','8.300000000000000001','1/7','1/0',
    '9007199254740992','9007199254740991.000000000000001','0x10','1e3','NaN','Infinity','',true,null]) {
    assert.throws(() => tickUnits(value,960),String(value))
  }
  assert.throws(() => tickUnits('-1/3',960))
  const editor = command(newEditor(),'note C4 0 1')
  const before = structuredClone(editor)
  assert.throws(() => command(editor,'note D4 8.300000000000000001 1'))
  assert.deepEqual(editor,before)
})
