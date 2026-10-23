import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { newEditor, editorCommand, editorPlayback } from '../sequencer-editor.mjs'
import { importMidiSource, midiSourcePattern, exportMidiSourcePattern } from '../midi-source.mjs'
import { sequenceEvents } from '../sequencer-project.mjs'
midiFiles(JZZ)
const commands = (editor, lines) => lines.reduce((value, line) => editorCommand(value, line).editor, editor)

async function preparation(playback, format, options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'masc-cursor-audition-'))
  const worker = new Worker(new URL('../sequencer-worker.mjs', import.meta.url))
  try {
    const received = once(worker, 'message'), path = join(directory, 'prepared')
    worker.postMessage({ id: 1, path, project: playback.project, cancel: new SharedArrayBuffer(4),
      options: { ...playback.options, ...options, format } })
    const [result] = await received
    assert.equal(result.ok, true, result.error)
    return { result: result.result, bytes: await readFile(path) }
  } finally { await worker.terminate(); await rm(directory, { recursive: true, force: true }) }
}

test('cursor audition crops sustained phrase voices across tracks through actual MIDI, VST and FluidSynth preparation', async () => {
  const editor = commands(newEditor(), ['tempo 120', 'note C4 1 4 80', 'track-add Bass', 'note C2 2 4 70',
    'loop 1 5', 'cursor 3 C2'])
  const before = structuredClone(editor), audition = editorPlayback(editor, { fromCursor: true })
  assert.deepEqual(audition.range, { start: 2880, end: 15360, repeat: false })
  const schedule = sequenceEvents(audition.project, audition.options)
  assert.deepEqual(schedule.events.filter(event => event.kind === 'on').map(event => event.tick), [0, 0])
  const midi = JSON.parse((await preparation(audition, 'midi')).bytes)
  assert.equal(midi.duration, 6.5)
  assert.deepEqual(midi.events.filter(event => event.kind === 'off').map(event => event.seconds), [1, 1.5])
  const vst = midiSourcePattern(importMidiSource((await preparation(audition, 'vst-midi')).bytes))
  assert.deepEqual(vst.notes.map(note => [note.start, note.duration, note.velocity]), [[0, 1920, 80], [0, 2880, 70]])
  const fluid = JSON.parse((await preparation(audition, 'fluid-plan')).bytes)
  assert.equal(fluid.frames, 286650)
  assert.deepEqual(fluid.ports[0].events.filter(event => event.bytes[0] >> 4 === 9).map(event => event.frame), [0, 0])
  const repeating = editorPlayback(editor, { loop: true, fromCursor: true })
  assert.deepEqual(repeating.range, { start: 2880, end: 4800, repeat: true })
  assert.equal(sequenceEvents(repeating.project, repeating.options).seconds, 1)
  assert.deepEqual(editor, before)
})

for (const smpte of [false, true]) for (const type of [1, 2]) {
  test(`${smpte ? 'SMPTE' : 'PPQ1001'} SMF${type} auditions preserve source bytes, expression and independent pattern selection`, async () => {
    const file = smpte ? new JZZ.MIDI.SMF(type, 29, 80) : new JZZ.MIDI.SMF(type, 1001)
    file.push(new JZZ.MIDI.SMF.MTrk().add(0, JZZ.MIDI.control(0, 64, 127))
      .add(0, JZZ.MIDI.noteOn(0, 60, 90)).add(1001, JZZ.MIDI.noteOff(0, 60, 47))
      .add(2002, JZZ.MIDI.control(0, 64, 0)).add(3003, JZZ.MIDI.smfEndOfTrack()))
    file.push(new JZZ.MIDI.SMF.MTrk().add(0, JZZ.MIDI.noteOn(1, 48, 70))
      .add(3003, JZZ.MIDI.noteOff(1, 48, 12)).add(3003, JZZ.MIDI.smfEndOfTrack()))
    const source = importMidiSource(file.toUint8Array())
    const editor = { ...newEditor(source, { pattern: type === 2 ? 0 : undefined }), tick: 500 }
    const before = structuredClone(editor), audition = editorPlayback(editor, { fromCursor: true })
    const midi = JSON.parse((await preparation(audition, 'midi', { midiOutput: '42' })).bytes)
    assert.equal(midi.schemaVersion, 3)
    assert.deepEqual(midi.sources[0].timeline.events[0].bytes, [176, 64, 127])
    assert.equal(midi.sourceWindow.start, 500); assert.equal(midi.sourceWindow.end, 3003)
    assert.equal(midi.regions[0].repeatCount, 1)
    const { numerator, denominator } = midi.sourceWindow.periodNanoseconds
    const n = BigInt(numerator), d = BigInt(denominator)
    assert.equal(midi.duration, Number(n / d + (n % d ? 1n : 0n)) / 1e9)
    const vst = await preparation(audition, 'vst-midi')
    // VST's existing SMF adapter selects one SMF2 pattern and represents SMPTE
    // as a fixed PPQ clock. Audition must retain its complete pre-cut render.
    assert.deepEqual(vst.bytes, Buffer.from(exportMidiSourcePattern(source, { pattern: editor.pattern })))
    assert.equal(vst.result.sourceWindow.start, 500)
    const fluid = JSON.parse((await preparation(audition, 'fluid-plan')).bytes)
    assert.equal(fluid.sourceWindow.start, 500)
    assert.deepEqual(fluid.ports[0].events[0], { frame: 0, bytes: [176, 64, 127] })
    assert.deepEqual(editor, before)
  })
}

test('invalid cursor windows and missing patterns refuse admission without editing locators or history', () => {
  const editor = commands(newEditor(), ['loop 2 4'])
  for (const tick of [0, 3840, 5000]) {
    const value = { ...editor, tick }, before = structuredClone(value)
    assert.throws(() => editorPlayback(value, { loop: true, fromCursor: true }), /cursor/)
    assert.deepEqual(value, before)
  }
  const file = new JZZ.MIDI.SMF(2, 960)
  for (let i = 0; i < 2; i++) file.push(new JZZ.MIDI.SMF.MTrk().add(0, JZZ.MIDI.smfEndOfTrack()))
  assert.throws(() => editorPlayback(newEditor(importMidiSource(file.toUint8Array())), { fromCursor: true }), /pattern/)
  const point = new JZZ.MIDI.SMF(0, 960)
  point.push(new JZZ.MIDI.SMF.MTrk().add(0, JZZ.MIDI.noteOn(0, 60, 90)).add(0, JZZ.MIDI.noteOff(0, 60, 0)))
  assert.throws(() => editorPlayback(newEditor(importMidiSource(point.toUint8Array())), { fromCursor: true }), /cursor/)
  assert.equal(editorCommand(editor, 'play-cursor').effect.kind, 'play-cursor')
})
