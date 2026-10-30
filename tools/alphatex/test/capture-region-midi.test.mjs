import test, { before, after } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, mkdir, rm, readdir, readFile } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import JZZ from 'jzz'
import { capturedMidiFixture, packet } from './helpers/captured-midi-fixture.mjs'
import { importCaptureMidi, saveArrangement, loadArrangement } from '../arrangement-files.mjs'
import { arrangementEditor, arrangementCommand, arrangementImported, arrangementAction } from '../arrangement-editor.mjs'
import { midiSourcePattern } from '../midi-source.mjs'
import { newEditor, editorCommand } from '../sequencer-editor.mjs'

const execute = promisify(execFile)
let build, nativeExecutable
before(async () => {
  build = await mkdtemp(join(tmpdir(), 'masc-capture-region-native-'))
  nativeExecutable = join(build, 'music-arrangement')
  const native = ['WaveArrangement', 'WaveLoopClock', 'SourceAudioClock', 'CaptureAudioClock', 'PulseAudioClock',
    'PulseLoopClock', 'MidiTransport', 'UmpTransport', 'UmpOutput', 'UmpRegions', 'HybridMidiTransport', 'UmpLoopTransport', 'UmpState']
  await execute('xcrun', ['swiftc', '-parse-as-library', '-D', 'MIDI_LIBRARY', '-O',
    ...native.map(name => fileURLToPath(new URL(`../native/${name}.swift`, import.meta.url))),
    '-o', nativeExecutable, '-framework', 'AVFoundation', '-framework', 'CoreAudio', '-framework', 'CoreMIDI'])
})
after(async () => { if (build) await rm(build, { recursive: true, force: true }) })

const fixture = (run, rows) => capturedMidiFixture(async data => {
  const directory = join(data.root, 'scratch'); await mkdir(directory)
  const derive = cut => importCaptureMidi(data.imported.project, data.imported.asset,
    { sourceRoot: dirname(data.path), directory, cut, nativeExecutable })
  await run({ ...data, directory, derive })
}, rows)
const sourceOf = result => result.project.assets.at(-1).source
const channelEvents = source => midiSourcePattern(source).events.filter(event => event.kind === 'channel')

test('actual native reconstruction and Worker derive a selected multi-input cut for independent harmony edits and portable placement', () => fixture(async data => {
  const { imported, path, root, directory } = data
  const worker = new Worker(new URL('../arrangement-worker.mjs', import.meta.url)); let id = 0
  const request = async value => {
    const pending = once(worker, 'message'); worker.postMessage({ ...value, id: ++id })
    const [reply] = await pending; assert.equal(reply.ok, true, reply.error); return reply.result
  }
  try {
    let editor = arrangementEditor(imported.project)
    editor = arrangementCommand(editor, `region ${imported.asset} 4 2400001 4800000 3`).editor
    editor = arrangementCommand(editor, 'cursor 7').editor
    const original = structuredClone(editor.project), raw = original.clips[0]
    editor.asset = 'different-library-selection'
    const effect = arrangementCommand(editor, 'capture-midi-region').effect
    assert.deepEqual(effect, { kind: 'capture-midi-region', asset: imported.asset, tick: 6720, cut: { offset: '2400001', extent: '4800000' } })
    const result = await request({ ...effect, project: editor.project, sourceRoot: dirname(path), directory, nativeExecutable })
    editor = arrangementImported(editor, result)
    const source = sourceOf(result), pattern = midiSourcePattern(source)
    assert.deepEqual(pattern.diagnostics, []); assert.equal(pattern.notes.length, 5)
    assert.ok(pattern.notes.every(note => note.start === 0))
    assert.deepEqual([...new Set(pattern.notes.map(note => note.port))].sort(), [0, 1])
    assert.ok(pattern.notes.every(note => note.channel === 5))
    const end = Number((4800000n * 125n * 960n * 2n + 3n * 437956n * 1000n) / (6n * 437956n * 1000n))
    assert.equal(pattern.ticks, end)
    assert.ok(pattern.notes.filter(note => note.port === 0).every(note => note.duration === end))
    const provenance = JSON.parse(Buffer.from(pattern.events.find(event => event.kind === 'meta' && event.type === 0x7f).data).toString())
    assert.deepEqual(provenance.cut, effect.cut)
    let child = newEditor(source)
    child = editorCommand(child, 'channel 6').editor
    child = editorCommand(child, 'revoice Cmaj7 drop2').editor
    assert.deepEqual(midiSourcePattern(child.project).notes.filter(note => note.port === 0).map(note => note.pitch).sort((a, b) => a - b), [55, 60, 64, 71])
    editor = arrangementImported(editor, await request({ kind: 'import-phrase', project: editor.project, document: child.project }))
    editor = arrangementCommand(editor, 'cursor 7').editor; editor = arrangementAction(editor, { kind: 'place' })
    assert.equal(editor.project.clips.at(-1).position, 6720)
    assert.deepEqual(editor.project.clips[0], raw); assert.deepEqual(editor.project.assets[0], original.assets[0])
    const undone = arrangementAction(arrangementImported(arrangementEditor(original), result), { kind: 'undo' })
    assert.deepEqual(undone.project, original)
    const copy = join(root, 'portable/song.json'); await saveArrangement(copy, editor.project, null, { sourceRoot: dirname(path) })
    assert.deepEqual((await loadArrangement(copy)).project, editor.project)
    for (const part of Object.values(original.assets[0].parts)) assert.deepEqual(await readFile(join(dirname(copy), part.file)), await readFile(join(dirname(path), part.file)))
    assert.deepEqual(await readdir(directory), [])
  } finally { await worker.terminate() }
}))

test('pedal-held released voices enter as point keys with original release dynamics and explicit end cleanup', () => fixture(async ({ derive }) => {
  const source = sourceOf(await derive({ offset: '5', extent: '1000000' })), pattern = midiSourcePattern(source)
  assert.deepEqual(pattern.diagnostics, [])
  assert.deepEqual(pattern.notes.map(note => [note.pitch, note.duration]).sort((a, b) => a[0] - b[0]), [[60, 0], [64, 0]])
  const wire = channelEvents(source)
  assert.ok(wire.some(event => event.tick === 0 && event.bytes[0] === 0x85 && event.bytes[1] === 60 && event.bytes[2] === 42))
  for (const pedal of [64, 66, 69]) assert.ok(wire.some(event => event.tick === pattern.ticks && event.bytes[0] === 0xb5 && event.bytes[1] === pedal && event.bytes[2] === 0))
}, [packet(0n, 'A', [JZZ.UMP.noteOn(0, 5, 60, 100)]), packet(1n, 'A', [JZZ.UMP.control(0, 5, 66, 127)]),
  packet(2n, 'A', [JZZ.UMP.noteOff(0, 5, 60, 42)]), packet(3n, 'A', [JZZ.UMP.control(0, 5, 64, 127)]),
  packet(4n, 'A', [JZZ.UMP.noteOn(0, 5, 64, 90)]), packet(5n, 'A', [JZZ.UMP.noteOff(0, 5, 64, 43)]),
  packet(2000000n, 'A', [JZZ.UMP.control(0, 5, 66, 0), JZZ.UMP.control(0, 5, 64, 0)])]))

test('expired attributes and unsupported suffix stay outside the selected performance; idle declared inputs need no fake binding', () => fixture(async ({ imported, derive, path }) => {
  await assert.rejects(importCaptureMidi(imported.project, imported.asset, { sourceRoot: dirname(path) }), /attributes/)
  const source = sourceOf(await derive({ offset: '2000001', extent: '1000000' }))
  assert.deepEqual(midiSourcePattern(source).notes.map(note => note.pitch), [62])
  await assert.rejects(derive({ offset: '0', extent: '1000000' }), /attributes/)
}, [packet(0n, 'A', [JZZ.UMP([0x40, 0x95, 60, 3, 0x90, 0, 0x12, 0x34])]),
  packet(1000000n, 'A', [JZZ.UMP.umpNoteOff(0, 5, 60, 0)]),
  packet(2000000n, 'A', [JZZ.UMP.umpNoteOn(0, 5, 62, 0x9000)]),
  packet(4000000n, 'A', [JZZ.UMP.umpNoteOff(0, 5, 62, 0), JZZ.UMP([0x40, 0x95, 67, 3, 0x90, 0, 0x12, 0x34])])]))

const exclusiveRows = [
  packet(200000n, 'A', [JZZ.UMP([0x30, 0x12, 1, 2, 0, 0, 0, 0])]),
  packet(250000n, 'A', [JZZ.UMP([0x10, 0xf8, 0, 0])]),
  packet(300000n, 'A', [JZZ.UMP([0x30, 0x31, 3, 0, 0, 0, 0, 0])]),
  packet(400000n, 'A', [JZZ.UMP.noteOn(0, 0, 60, 90)]), packet(800000n, 'A', [JZZ.UMP.noteOff(0, 0, 60, 20)]),
]
test('a sub-tick cut closes held keys at its rounded boundary independently of the SMF container minimum', () => fixture(async ({ derive }) => {
  const source = sourceOf(await derive({ offset: '1', extent: '1' })), pattern = midiSourcePattern(source)
  assert.deepEqual(pattern.diagnostics, [])
  assert.equal(pattern.ticks, 1)
  assert.deepEqual(pattern.notes.map(note => [note.pitch, note.start, note.duration]), [[60, 0, 0]])
  assert.ok(channelEvents(source).filter(event => event.bytes[0] === 0x80 || event.bytes[0] === 0xb0).every(event => event.tick === 0))
}, [packet(0n, 'A', [JZZ.UMP.noteOn(0, 0, 60, 90)]), packet(100n, 'A', [JZZ.UMP.noteOff(0, 0, 60, 20)])]))

test('complete in-cut SysEx7 and realtime retain original fragment timing while historical or cut-through opaque state refuses reconstruction', () => fixture(async ({ derive }) => {
  const source = sourceOf(await derive({ offset: '100000', extent: '800000' }))
  const sx = midiSourcePattern(source).events.filter(event => event.kind === 'sysex')
  assert.deepEqual(sx.map(event => [event.status, event.data]), [[0xf0, [1, 2]], [0xf7, [0xf8]], [0xf7, [3, 0xf7]]])
  assert.ok(sx[2].tick > sx[0].tick)
  await assert.rejects(derive({ offset: '250000', extent: '600000' }), /opaque/)
  await assert.rejects(derive({ offset: '350000', extent: '500000' }), /opaque/)
}, exclusiveRows))

test('cutting through an exclusive tail or its non-realtime interruption cannot publish a partial source', () => fixture(async ({ derive, imported, directory }) => {
  const original = structuredClone(imported.project)
  await assert.rejects(derive({ offset: '100000', extent: '170000' }), /SysEx|exclusive/)
  assert.deepEqual(imported.project, original); assert.deepEqual(await readdir(directory), [])
}, [packet(100001n, 'A', [JZZ.UMP.noteOn(0, 0, 60, 90)]), ...exclusiveRows]))

test('a retained System Common interruption still refuses an orphan SysEx continuation', () => fixture(async ({ derive, directory }) => {
  await assert.rejects(derive({ offset: '100000', extent: '800000' }), /interrupts.*SysEx/)
  assert.deepEqual(await readdir(directory), [])
}, exclusiveRows.map((row, index) => index === 1 ? packet(250000n, 'A', [JZZ.UMP([0x10, 0xf2, 1, 2])]) : row)))

test('invalid, audio-only and cancelled region selections leave the original arrangement intact', () => fixture(async ({ derive, imported, path, directory }) => {
  let editor = arrangementEditor(imported.project)
  assert.throws(() => arrangementCommand(editor, 'capture-midi-region'), /original captured MIDI region/)
  editor = arrangementCommand(editor, `place ${imported.asset} 0`).editor
  editor = arrangementCommand(editor, 'split-take').editor
  // split-take keeps audio selected; the explicit MIDI region is independently addressable.
  const audio = editor.project.clips.find(clip => clip.component === 'audio')
  const selected = { ...editor, region: audio.id }
  assert.throws(() => arrangementCommand(selected, 'capture-midi-region'), /original captured MIDI region/)
  await assert.rejects(derive({ offset: '0', extent: '0' }))
  const aborted = new AbortController(); aborted.abort()
  await assert.rejects(importCaptureMidi(imported.project, imported.asset, { sourceRoot: dirname(path), directory,
    cut: { offset: '0', extent: '1000000' }, nativeExecutable, signal: aborted.signal }), { name: 'AbortError' })
  assert.deepEqual(await readdir(directory), [])
}))
