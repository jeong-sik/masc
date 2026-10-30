import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { mkdir, readFile, rm } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import JZZ from 'jzz'
import { packet, capturedMidiFixture } from './helpers/captured-midi-fixture.mjs'
import { newUmpEditor, umpEditorCommand } from '../ump-editor.mjs'
import { captureRange, captureBeatsToTicks } from '../capture-time.mjs'
import { materializeUmp } from '../ump-source.mjs'
import { arrangementEditor, arrangementCommand, arrangementImported } from '../arrangement-editor.mjs'
import { saveArrangement, loadArrangement, exportUmpCapture, readUmpCapture } from '../arrangement-files.mjs'
import { prepareCapturedPlayback } from '../capture-playback.mjs'

const origin = 10000000000000000000n, hash = 'a'.repeat(64)
const rows = () => [packet(-100n, 'A', [JZZ.UMP.umpNoteOn(0, 0, 60, 0), JZZ.UMP.umpPnPitchBend(0, 0, 60, 0x87654321)]),
  packet(12000000n, 'A', [JZZ.UMP.umpNoteOff(0, 0, 60, 0xfedc)])]
const asset = { name: 'Beats', parts: { midi: { sha256: hash } }, midiTime: { first: String(origin - 100n), last: String(origin + 12000000n) },
  manifest: { sampleRate: 48000, audioFrames: '0', midiPacketCount: '2', clock: { kind: 'mach-host-time', numer: 125, denom: 3,
    requestedStart: String(origin), firstAudioHostTime: null } } }
const command = (editor, line) => umpEditorCommand(editor, line).editor

test('fractional project beats share the fixed source zero and immutable note/expression history', () => {
  const packets = rows(), snapshot = structuredClone(packets), initial = newUmpEditor(asset, packets, { tempo: 120 })
  let edited = command(initial, 'at-beats -1/3')
  assert.equal(edited.notes[0].hostTime, String(origin - 100n - 4000000n))
  assert.equal(captureRange(edited.asset).origin, edited.notes[0].hostTime)
  edited = command(command(edited, 'select-expression 0:2'), 'at-beats 1/3')
  assert.equal(edited.expressions[0].hostTime, String(origin - 100n + 4000000n))
  edited = command(command(edited, 'select 0:0'), 'note-beats 1:0 1/6 2/3')
  assert.equal(edited.notes[0].hostTime, String(origin - 100n + 2000000n))
  assert.equal(edited.events.find(row => row.id === '1:0').hostTime, String(origin - 100n + 8000000n))
  edited = command(edited, 'duration-beats 1:0 .5')
  assert.equal(edited.events.find(row => row.id === '1:0').hostTime, String(origin - 100n + 8000000n))
  edited = command(edited, 'pitch-absolute 60.5')
  edited = command(command(edited, 'select-expression 0:2'), 'value32 4294967295')
  edited = command(edited, 'shift-beats -1/6')
  assert.equal(edited.expressions[0].hostTime, String(origin - 100n + 2000000n))
  assert.deepEqual(command(command(edited, 'undo'), 'redo').asset, edited.asset)
  assert.deepEqual(packets, snapshot); assert.equal(edited.tempo, 120)
})

test('beat conversion rounds once at the native clock, including signed half ties and noninteger project tempos', () => {
  // Constants were calculated independently with Python Fraction, including
  // Fraction(float) for the same binary64 tempo used by native scheduling.
  for (const [tempo, beat, expected] of [[137, '1/3', 3503650n], [137, '2/3', 7007299n],
    [137.1, '1/3', 3501094n], [137.1, '1/7', 1500469n], [.1, '1/7', 2057142857n], [60000000, '1/3', 8n]]) {
    assert.equal(captureBeatsToTicks(asset, beat, tempo), expected)
    assert.equal(captureBeatsToTicks(asset, `-${beat}`, tempo), -expected)
  }
  const minute = { ...asset, manifest: { ...asset.manifest, clock: { ...asset.manifest.clock, numer: 60000000000, denom: 1 } } }
  for (const [beat, expected] of [['.5', 1n], ['-.5', -1n], ['3/2', 2n], ['-3/2', -2n], ['.499', 0n]]) {
    assert.equal(captureBeatsToTicks(minute, beat, 1), expected)
  }
  const start = newUmpEditor(asset, rows(), { tempo: 137 })
  const absolute = command(start, 'note-beats 1:0 1/3 2/3')
  const duration = command(absolute, 'duration-beats 1:0 1/3')
  // A rounded duration is added to the current whole-tick start; endpoints
  // entered separately instead round each source-relative endpoint once.
  assert.equal(BigInt(duration.events.at(-1).hostTime) - BigInt(absolute.events.at(-1).hostTime), 1n)
})

test('missing tempo, malformed beat fractions, bounds and invalid releases refuse whole immutable candidates', () => {
  const noTempo = newUmpEditor(asset, rows())
  assert.throws(() => command(noTempo, 'at-beats 1/3'))
  assert.equal(command(noTempo, 'at-seconds .25').notes[0].hostTime, String(origin - 100n + 6000000n))
  for (const tempo of [0, -1, NaN, Infinity, '120', null]) assert.throws(() => newUmpEditor(asset, rows(), { tempo }))
  const initial = newUmpEditor(asset, rows(), { tempo: 120 }), snapshot = structuredClone(initial)
  for (const line of ['at-beats 1/0', 'at-beats 1/-3', 'at-beats 1.5/3', 'at-beats 1e3', 'at-beats NaN',
    'at-beats 0x10', 'shift-beats Infinity', 'at-beats 1/2/3', 'note-beats 0:2 0 1', 'note-beats 1:0 1 0',
    'note-beats 1:0 0 .00000000001', 'duration-beats 1:0 0', 'duration-beats 1:0 -1/3',
    'duration-beats 1:0 .00000000001', 'at-beats 999999999999999999999999', 'at-beats -999999999999999999999999']) {
    assert.throws(() => command(initial, line))
  }
  assert.deepEqual(initial, snapshot)
  const boundary = { ...asset, midiTime: { first: '18446744073709551614', last: '18446744073709551614' },
    manifest: { ...asset.manifest, clock: { ...asset.manifest.clock, requestedStart: '18446744073709551614', numer: 1, denom: 1 } } }
  const event = [{ ...rows()[0], hostTime: '18446744073709551614' }]
  const end = newUmpEditor(boundary, event, { tempo: 60 })
  assert.equal(command(end, 'at-beats .000000001').notes[0].hostTime, '18446744073709551615')
  assert.throws(() => command(end, 'at-beats .000000002'))
  const zero = { ...boundary, midiTime: { first: '0', last: '0' }, manifest: { ...boundary.manifest, clock: { ...boundary.manifest.clock, requestedStart: '0' } } }
  assert.throws(() => command(newUmpEditor(zero, [{ ...event[0], hostTime: '0' }], { tempo: 60 }), 'at-beats -.000000001'))
})

test('later project tempos change future beat input only, preserving the already authored capture clock and raw bytes', () => {
  const packets = rows(), initial = newUmpEditor(asset, packets, { tempo: 120 })
  const edited = command(initial, 'note-beats 1:0 1/3 2/3')
  const reopened = newUmpEditor(edited.asset, packets, { tempo: 60 })
  assert.deepEqual(reopened.events, edited.events); assert.equal(reopened.asset, edited.asset)
  const shifted = command(reopened, 'shift-beats 1/3')
  assert.equal(BigInt(shifted.notes[0].hostTime) - BigInt(edited.notes[0].hostTime), 8000000n)
  const reset = command(command(command(edited, 'reset-time'), 'select-event 1:0'), 'reset-time')
  assert.deepEqual(reset.asset, initial.asset); assert.deepEqual(materializeUmp(packets, reset.asset.ump, hash), packets)
})

test('actual Worker, standalone/arrangement native plans and portable reopen consume the same beat-authored source clock', () => capturedMidiFixture(async ({ root, path, imported, rows: packets }) => {
  const directory = join(root, 'scratch'); await mkdir(directory)
  const worker = new Worker(new URL('../arrangement-worker.mjs', import.meta.url)); let id = 0
  const options = { sourceRoot: dirname(path), directory }
  const request = async job => {
    const response = once(worker, 'message'); worker.postMessage({ ...job, id: ++id })
    const [message] = await response; assert.equal(message.ok, true, message.error); return message.result
  }
  try {
    const source = await request({ kind: 'prepare-ump', project: imported.project, asset: imported.asset, ...options })
    let edited = command(newUmpEditor(source.asset, source.packets, { tempo: imported.project.tempo }), 'note-beats 1:0 1/3 2/3')
    edited = command(command(edited, 'select-expression 0:2'), 'at-beats 1/2')
    const variant = await request({ kind: 'import-ump', project: imported.project, asset: imported.asset, ump: edited.asset.ump, ...options })
    let parent = arrangementImported(arrangementEditor(imported.project), variant)
    parent = arrangementCommand(parent, `place ${variant.asset} 0`).editor
    const snapshot = await request({ kind: 'prepare-take', project: parent.project, asset: variant.asset, ...options })
    const playback = await prepareCapturedPlayback(snapshot.directory, { directory, sourceBindings: [{ source: 'A', destination: '10' }] })
    const standalone = JSON.parse(await readFile(playback.path)).ump
    assert.deepEqual(standalone.packets.map(row => row.hostTime), [3503650n, 5255474n, 7007299n].map(offset => String(origin - 100n + offset)))
    const arranged = await request({ kind: 'prepare-capture', project: parent.project, sourceBindings: [{ asset: variant.asset, source: 'A', destination: '10' }], ...options })
    assert.deepEqual(JSON.parse(await readFile(arranged.path)).umpRegions.sources[0].timeline, standalone)
    const output = join(root, 'export'); await exportUmpCapture(parent.project, variant.asset, output, options)
    const copy = join(root, 'portable/song.json'); await saveArrangement(copy, parent.project, null, { sourceRoot: dirname(path) })
    await rm(dirname(path), { recursive: true, force: true })
    const reopened = await loadArrangement(copy)
    assert.equal(reopened.project.tempo, 137)
    const restored = await readUmpCapture(reopened.project, variant.asset, { sourceRoot: dirname(copy), directory })
    assert.deepEqual(restored.packets, packets)
    assert.equal(umpEditorCommand(newUmpEditor(restored.asset, restored.packets, { tempo: reopened.project.tempo }), 'clock').clock.sourceOrigin, String(origin - 100n))
    const reexport = join(root, 'reexport'); await exportUmpCapture(reopened.project, variant.asset, reexport, { sourceRoot: dirname(copy), directory })
    for (const file of ['midi.ump.jsonl', 'session.json', 'audio.wav', 'audio-blocks.jsonl', 'original-midi.ump.jsonl', 'ump-source.json']) assert.deepEqual(await readFile(join(output, file)), await readFile(join(reexport, file)))
  } finally { await worker.terminate() }
}, rows()))
