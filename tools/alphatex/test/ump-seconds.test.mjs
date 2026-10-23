import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { mkdir, readFile, rm } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import JZZ from 'jzz'
import { packet, capturedMidiFixture } from './helpers/captured-midi-fixture.mjs'
import { newUmpEditor, umpEditorCommand } from '../ump-editor.mjs'
import { captureRange, captureSecondsToTicks, captureSecondsAtHost } from '../capture-time.mjs'
import { materializeUmp } from '../ump-source.mjs'
import { arrangementEditor, arrangementCommand, arrangementImported } from '../arrangement-editor.mjs'
import { saveArrangement, loadArrangement, exportUmpCapture, readUmpCapture } from '../arrangement-files.mjs'
import { prepareCapturedPlayback } from '../capture-playback.mjs'

const origin = 10000000000000000000n, hash = 'a'.repeat(64)
const rows = () => [packet(-100n, 'A', [JZZ.UMP.umpNoteOn(0, 0, 60, 0), JZZ.UMP.umpPnPitchBend(0, 0, 60, 0x87654321)]),
  packet(12000000n, 'A', [JZZ.UMP.umpNoteOff(0, 0, 60, 0xfedc)])]
const asset = { name: 'Timing', parts: { midi: { sha256: hash } }, midiTime: { first: String(origin - 100n), last: String(origin + 12000000n) },
  manifest: { sampleRate: 48000, audioFrames: '0', midiPacketCount: '2', clock: { kind: 'mach-host-time', numer: 125, denom: 3,
    requestedStart: String(origin), firstAudioHostTime: null } } }
const command = (editor, line) => umpEditorCommand(editor, line).editor

test('decimal seconds author exact source-relative times and duration without changing their origin after earlier edits', () => {
  const original = rows(), snapshot = structuredClone(original), initial = newUmpEditor(asset, original)
  const early = command(initial, 'at-seconds -.125')
  assert.equal(early.notes[0].hostTime, String(origin - 100n - 3000000n))
  assert.equal(captureRange(early.asset).origin, early.notes[0].hostTime)
  const expression = command(command(early, 'select-expression 0:2'), 'at-seconds .25')
  assert.equal(expression.expressions[0].hostTime, String(origin - 100n + 6000000n))
  const inspected = umpEditorCommand(expression, 'clock')
  assert.equal(inspected.editor, expression)
  assert.deepEqual(inspected.clock, { sourceOrigin: String(origin - 100n), hostTime: String(origin - 100n + 6000000n),
    originalHostTime: String(origin - 100n), seconds: .25 })
  const span = command(command(expression, 'select 0:0'), 'note-seconds 1:0 .125 .5')
  assert.equal(span.notes[0].hostTime, String(origin - 100n + 3000000n))
  assert.equal(span.events.find(e => e.id === '1:0').hostTime, String(origin - 100n + 12000000n))
  const duration = command(span, 'duration-seconds 1:0 .25')
  assert.equal(duration.events.find(e => e.id === '1:0').hostTime, String(origin - 100n + 9000000n))
  const shifted = command(duration, 'shift-seconds +.125')
  assert.equal(shifted.notes[0].hostTime, String(origin - 100n + 6000000n))
  assert.deepEqual(command(command(shifted, 'undo'), 'redo').asset, shifted.asset)
  assert.deepEqual(original, snapshot)
  assert.equal(captureSecondsAtHost(asset, early.notes[0].hostTime), -.125)
})

test('nearest whole-tick quantization uses decimal rationals and exact half ties away from zero', () => {
  for (const [text, expected] of [['.1', 2400000n], ['+.000000125', 3n], ['-.000000125', -3n],
    ['.0000000208', 0n], ['-.0000000208', 0n], ['.0000000209', 1n], ['-.0000000209', -1n]]) assert.equal(captureSecondsToTicks(asset, text), expected)
  const nano = { ...asset, manifest: { ...asset.manifest, clock: { ...asset.manifest.clock, numer: 1, denom: 1 } } }
  for (const [text, expected] of [['.0000000005', 1n], ['-.0000000005', -1n], ['.0000000015', 2n], ['-.0000000015', -2n]]) assert.equal(captureSecondsToTicks(nano, text), expected)
  assert.equal(captureSecondsToTicks(nano, '9007199254740993.000000001'), 9007199254740993000000001n)
  assert.throws(() => command(newUmpEditor(nano, rows()), 'duration-seconds 1:0 .0000000004'))
})

test('malformed decimals, overflow/underflow and invalid explicit releases refuse immutable whole candidates', () => {
  const initial = newUmpEditor(asset, rows()), before = structuredClone(initial)
  for (const line of ['at-seconds 1e3', 'shift-seconds NaN', 'at-seconds Infinity', 'at-seconds 0x10',
    'at-seconds --.1', 'at-seconds 1.', 'duration-seconds 1:0 -.1', 'duration-seconds 1:0 0',
    'note-seconds 0:2 0 .1', 'note-seconds 1:0 .5 .1', 'at-seconds 9007199254740993.1',
    'at-seconds -9007199254740993.1']) assert.throws(() => command(initial, line))
  assert.deepEqual(initial, before)
  const end = { ...asset, midiTime: { first: '18446744073709551614', last: '18446744073709551614' },
    manifest: { ...asset.manifest, clock: { ...asset.manifest.clock, requestedStart: '18446744073709551614', numer: 1, denom: 1 } } }
  const event = [{ ...rows()[0], hostTime: '18446744073709551614' }], near = newUmpEditor(end, event)
  assert.equal(command(near, 'at-seconds .000000001').notes[0].hostTime, '18446744073709551615')
  assert.throws(() => command(near, 'at-seconds .000000002'))
  const zero = { ...end, midiTime: { first: '0', last: '0' }, manifest: { ...end.manifest, clock: { ...end.manifest.clock, requestedStart: '0' } } }
  assert.throws(() => command(newUmpEditor(zero, [{ ...event[0], hostTime: '0' }]), 'at-seconds -.000000001'))
})

test('decimal editing composes with native value/pitch fields and restores the exact original after reset', () => {
  const packets = rows(), initial = newUmpEditor(asset, packets)
  let edited = command(command(initial, 'at-seconds .1'), 'pitch-absolute 60.5')
  edited = command(command(command(edited, 'select-expression 0:2'), 'value32 4294967295'), 'shift-seconds .125')
  const expressionTime = edited.expressions[0].hostTime
  edited = command(edited, 'reset-expression')
  assert.equal(edited.expressions[0].hostTime, expressionTime); assert.equal(edited.expressions[0].value, 0x87654321)
  edited = command(edited, 'reset-time'); edited = command(command(edited, 'select 0:0'), 'reset-note')
  assert.equal(edited.notes[0].hostTime, String(origin - 100n + 2400000n))
  edited = command(edited, 'reset-time')
  assert.deepEqual(edited.asset, initial.asset); assert.deepEqual(materializeUmp(packets, edited.asset.ump, hash), packets)
})

test('actual Worker and native playback preparation retain seconds-authored ticks through variant export and portable reopen', () => capturedMidiFixture(async ({ root, path, imported, rows: packets }) => {
  const directory = join(root, 'scratch'); await mkdir(directory)
  const worker = new Worker(new URL('../arrangement-worker.mjs', import.meta.url)); let id = 0
  const options = { sourceRoot: dirname(path), directory }
  const request = async job => {
    const response = once(worker, 'message'); worker.postMessage({ ...job, id: ++id })
    const [message] = await response; assert.equal(message.ok, true, message.error); return message.result
  }
  try {
    const source = await request({ kind: 'prepare-ump', project: imported.project, asset: imported.asset, ...options })
    let edited = command(newUmpEditor(source.asset, source.packets), 'note-seconds 1:0 .1 .25')
    edited = command(command(edited, 'select-expression 0:2'), 'at-seconds .125')
    const variant = await request({ kind: 'import-ump', project: imported.project, asset: imported.asset, ump: edited.asset.ump, ...options })
    let parent = arrangementImported(arrangementEditor(imported.project), variant)
    parent = arrangementCommand(parent, `place ${variant.asset} 0`).editor
    const snapshot = await request({ kind: 'prepare-take', project: parent.project, asset: variant.asset, ...options })
    const playback = await prepareCapturedPlayback(snapshot.directory, { directory, sourceBindings: [{ source: 'A', destination: '10' }] })
    const standalone = JSON.parse(await readFile(playback.path)).ump
    assert.deepEqual(standalone.packets.map(row => row.hostTime), [origin - 100n + 2400000n, origin - 100n + 3000000n, origin - 100n + 6000000n].map(String))
    const arranged = await request({ kind: 'prepare-capture', project: parent.project, sourceBindings: [{ asset: variant.asset, source: 'A', destination: '10' }], ...options })
    const arrangement = JSON.parse(await readFile(arranged.path)).umpRegions.sources[0].timeline
    assert.deepEqual(arrangement, standalone)
    const output = join(root, 'export'); await exportUmpCapture(parent.project, variant.asset, output, options)
    const copy = join(root, 'portable/song.json'); await saveArrangement(copy, parent.project, null, { sourceRoot: dirname(path) }); await rm(dirname(path), { recursive: true, force: true })
    const reopened = await loadArrangement(copy)
    const restored = await readUmpCapture(reopened.project, variant.asset, { sourceRoot: dirname(copy), directory })
    assert.deepEqual(restored.packets, packets)
    assert.equal(umpEditorCommand(newUmpEditor(restored.asset, restored.packets), 'clock').clock.sourceOrigin, String(origin - 100n))
    const reexport = join(root, 'reexport'); await exportUmpCapture(reopened.project, variant.asset, reexport, { sourceRoot: dirname(copy), directory })
    for (const file of ['midi.ump.jsonl', 'session.json', 'audio.wav', 'audio-blocks.jsonl', 'original-midi.ump.jsonl', 'ump-source.json']) assert.deepEqual(await readFile(join(output, file)), await readFile(join(reexport, file)))
  } finally { await worker.terminate() }
}, rows()))
