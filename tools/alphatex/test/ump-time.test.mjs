import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { mkdir, readFile, rm } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import JZZ from 'jzz'
import { packet, capturedMidiFixture } from './helpers/captured-midi-fixture.mjs'
import { materializeUmp, umpSourceEvents, editUmpTimes } from '../ump-source.mjs'
import { newUmpEditor, umpEditorCommand } from '../ump-editor.mjs'
import { captureRange } from '../capture-time.mjs'
import { arrangementEditor, arrangementCommand, arrangementImported } from '../arrangement-editor.mjs'
import { readUmpCapture, saveArrangement, loadArrangement, exportUmpCapture, importArrangementCapture } from '../arrangement-files.mjs'
import { newArrangement } from '../arrangement.mjs'
import { prepareCapturedPlayback } from '../capture-playback.mjs'
import { readCapture } from '../session-data.mjs'

const hash = 'a'.repeat(64), asset = { name: 'Recorded phrase', parts: { midi: { sha256: hash } } }
const origin = 10000000000000000000n
const command = (editor, line) => umpEditorCommand(editor, line).editor
const rows = () => [
  packet(-100n, 'A', [JZZ.UMP.umpNoteOn(3, 5, 60, 0), JZZ.UMP.umpNoteOn(3, 5, 64, 0xffff), JZZ.UMP.umpPnPitchBend(3, 5, 60, 0x87654321)]),
  packet(2400000n, 'B', [JZZ.UMP.umpNoteOn(9, 2, 60, 0x9001)]),
  packet(7200000n, 'B', [JZZ.UMP.umpNoteOff(9, 2, 60, 0x1234)]),
  packet(12000000n, 'A', [JZZ.UMP.umpNoteOff(3, 5, 60, 0xfedc), JZZ.UMP.umpNoteOff(3, 5, 64, 0x4567)]),
  { ...packet(12000001n, 'A', []), words: [0x50000000, 0x12345678, 0xabcdef01, 0x87654321, 0xf0000000, 1, 2, 3] },
]
const commands = ['note-time 3:0 10000000000004800000 10000000000014400000', 'pitch-absolute 60.5', 'velocity 65535',
  'select-expression 0:4', 'value32 4294967295', 'shift-time 1']
const edit = editor => commands.reduce(command, editor)

test('native message time edits split packets while preserving immutable identities, exact clocks, opaque words and mixed history', () => {
  const original = rows(), before = structuredClone(original), editor = edit(newUmpEditor(asset, original))
  assert.deepEqual(original, before)
  assert.equal(editor.notes[0].id, '0:0'); assert.equal(editor.notes[0].hostTime, '10000000000004800000')
  assert.equal(editor.notes[0].originalHostTime, '9999999999999999900')
  assert.equal(editor.notes[0].pitch, 30976); assert.equal(editor.notes[0].velocity, 65535)
  assert.equal(editor.expressions[0].id, '0:4'); assert.equal(editor.expressions[0].hostTime, '9999999999999999901')
  const projected = materializeUmp(original, editor.asset.ump, hash)
  assert.equal(projected.length, 9)
  assert.deepEqual(projected.map(row => row.hostTime), [origin - 100n, origin - 99n, origin + 2400000n,
    origin + 4800000n, origin + 7200000n, origin + 12000000n, origin + 12000001n, origin + 12000001n, origin + 14400000n].map(String))
  assert.deepEqual(projected.filter(row => row.timestampOrigin === 'authored').map(row => [row.words, row.recordedHostTime, row.recordedTimestampOrigin]), [
    [[0x43653c00, 0xffffffff], String(origin - 100n), 'packet'], [[0x43953c03, 0xffff7900], String(origin - 100n), 'packet'],
    [[0x43853c00, 0xfedc0000], String(origin + 12000000n), 'packet']])
  assert.deepEqual(projected.slice(6, 8).flatMap(row => row.words), before[4].words)
  assert.deepEqual(command(command(editor, 'undo'), 'redo').asset, editor.asset)
  const selected = command(command(editor, 'select 0:0'), 'velocity 0')
  assert.equal(selected.notes[0].velocity, 0); assert.equal(selected.notes[0].hostTime, '10000000000004800000')
  assert.equal(command(command(editor, 'select-event 3:0'), 'reset-time').asset.ump.timing.length, 2)
  let reset = command(command(editor, 'select-event 3:0'), 'reset-time')
  reset = command(command(reset, 'select-event 0:0'), 'reset-time')
  reset = command(command(reset, 'select-expression 0:4'), 'reset-time')
  assert.equal(reset.asset.ump.timing, undefined); assert.equal(reset.expressions[0].value, 0xffffffff)
})

test('explicit release duration keeps repeated note indices operator-addressed; other sources and voices remain separate', () => {
  const editor = newUmpEditor(asset, rows())
  const duration = command(editor, 'duration-ticks 3:0 20000000')
  assert.equal(duration.events.find(event => event.id === '3:0').hostTime, String(origin - 100n + 20000000n))
  for (const line of ['duration-ticks 2:0 10', 'duration-ticks 3:2 10', 'note-time 3:0 5 5', 'note-time 3:0 7 6',
    'duration-ticks 3:0 0', 'shift-time 18446744073709551615', 'time -1', 'time 18446744073709551616', 'time 1e9']) assert.throws(() => command(editor, line))
  assert.deepEqual(editor.asset, asset)
  const repeated = [packet(0n, 'A', [JZZ.UMP.umpNoteOn(3, 5, 60, 1), JZZ.UMP.umpNoteOn(3, 5, 60, 2)]),
    packet(5n, 'A', [JZZ.UMP.umpNoteOff(3, 5, 60, 3), JZZ.UMP.umpNoteOff(3, 5, 60, 4)])]
  const declared = command(newUmpEditor(asset, repeated), `note-time 1:2 ${origin + 1n} ${origin + 8n}`)
  assert.equal(declared.events.find(event => event.id === '1:0').hostTime, String(origin + 5n))
  assert.equal(declared.events.find(event => event.id === '1:2').hostTime, String(origin + 8n))
})

test('all native UMP event widths remain selectable, stable ties retain presentation order, and invalid batches refuse atomically', () => {
  const packets = rows(), raw = newUmpEditor(asset, [packets[4]])
  assert.deepEqual(raw.selection, { kind: 'event', id: '0:0' })
  const selected = command(raw, 'select-event 0:4')
  const moved = command(selected, 'shift-time -1')
  assert.equal(moved.events[1].hostTime, String(origin + 12000000n))
  assert.deepEqual(materializeUmp([packets[4]], moved.asset.ump, hash).map(row => row.words), [packets[4].words.slice(4), packets[4].words.slice(0, 4)])
  const same = editUmpTimes(packets, undefined, hash, [{ kind: 'time', id: '0:0', hostTime: String(origin - 99n) }, { kind: 'time', id: '0:2', hostTime: String(origin - 99n) }])
  assert.deepEqual(materializeUmp(packets, same, hash).slice(1, 3).flatMap(row => row.words), packets[0].words.slice(0, 4))
  const snapshot = structuredClone(packets)
  for (const changes of [[{ kind: 'time', id: '0:0', hostTime: '1' }, { kind: 'time', id: '0:1', hostTime: '2' }],
    [{ kind: 'time', id: '0:0', hostTime: '01' }], [{ kind: 'time', id: '0:0', hostTime: '1' }, { kind: 'reset', id: '0:0' }]]) assert.throws(() => editUmpTimes(packets, undefined, hash, changes))
  assert.deepEqual(packets, snapshot)
})

test('embedded JR/delta clocks refuse contradictory host edits only for their own source; reset and original wire stay intact', () => {
  for (const utility of [0x00101234, 0x00201234, 0x00300060, 0x00400001]) {
    const packets = [packet(0n, 'A', []), packet(1n, 'A', [JZZ.UMP.umpNoteOn(0, 0, 60, 1)]), packet(2n, 'B', [JZZ.UMP.umpNoteOn(0, 0, 60, 1)])]
    packets[0].words = [utility]
    const editor = newUmpEditor(asset, packets)
    assert.throws(() => command(editor, 'shift-time 1'), /embedded|Embedded/)
    assert.deepEqual(materializeUmp(packets, undefined, hash), packets)
    const other = command(command(editor, 'scope B 1 1'), 'shift-time 1')
    assert.equal(other.notes[1].hostTime, String(origin + 3n))
    assert.equal(command(other, 'reset-time').asset.ump, undefined)
  }
})

test('Worker timing variant shares extended clocks across standalone/arrangement plans, export and portable reopen', () => capturedMidiFixture(async ({ root, path, files, imported, rows: packets }) => {
  const directory = join(root, 'scratch'); await mkdir(directory)
  const worker = new Worker(new URL('../arrangement-worker.mjs', import.meta.url)); let id = 0
  const options = { sourceRoot: dirname(path), directory }
  const request = async job => {
    const response = once(worker, 'message'); worker.postMessage({ ...job, id: ++id })
    const [message] = await response; assert.equal(message.ok, true, message.error); return message.result
  }
  try {
    const source = await request({ kind: 'prepare-ump', project: imported.project, asset: imported.asset, ...options })
    const editor = edit(newUmpEditor(source.asset, source.packets))
    const variant = await request({ kind: 'import-ump', project: imported.project, asset: imported.asset, ump: editor.asset.ump, ...options })
    let parent = arrangementImported(arrangementEditor(imported.project), variant)
    parent = arrangementCommand(parent, `place ${variant.asset} 0`).editor
    const asset = parent.project.assets.at(-1), range = captureRange(asset)
    assert.deepEqual(range, { origin: String(origin - 100n), extent: '14400101' })
    assert.deepEqual(asset.manifest, source.asset.manifest); assert.deepEqual(asset.midiTime, source.asset.midiTime)
    const snapshot = await request({ kind: 'prepare-take', project: parent.project, asset: variant.asset, ...options })
    const read = await readCapture(snapshot.directory)
    assert.equal(read.manifest.midiPacketCount, '9'); assert.equal(read.manifest.clock.requestedStart, range.origin)
    assert.equal(read.midiTime.last, String(origin + 14400000n))
    assert.deepEqual(await readFile(join(snapshot.directory, 'audio.wav')), files['audio.wav'])
    const playback = await prepareCapturedPlayback(snapshot.directory, { directory, sourceBindings: [{ source: 'A', destination: '10' }, { source: 'B', destination: '11' }] })
    const standalone = JSON.parse(await readFile(playback.path)).ump
    const arranged = await request({ kind: 'prepare-capture', project: parent.project, sourceBindings: [{ asset: variant.asset, source: 'A', destination: '10' }, { asset: variant.asset, source: 'B', destination: '11' }], ...options })
    const arrangement = JSON.parse(await readFile(arranged.path)).umpRegions.sources[0]
    assert.deepEqual(standalone.clock, arrangement.timeline.clock)
    assert.equal(arrangement.extent, range.extent)
    assert.deepEqual(standalone.packets, arrangement.timeline.packets)
    const originalEvents = umpSourceEvents(packets)
    assert.deepEqual(arrangement.timeline.packets.filter(packet => packet.source === 'B'), packets.filter(packet => packet.source === 'B'))
    assert.equal(originalEvents.length, standalone.packets.length)
    const output = join(root, 'export'); await request({ kind: 'export-ump', project: parent.project, asset: variant.asset, path: output, ...options })
    assert.deepEqual(await readFile(join(output, 'original-midi.ump.jsonl')), Buffer.from(files['midi.ump.jsonl']))
    const copy = join(root, 'portable/song.json'); await saveArrangement(copy, parent.project, null, { sourceRoot: dirname(path) })
    await rm(dirname(path), { recursive: true, force: true })
    const reopened = await loadArrangement(copy)
    assert.deepEqual(reopened.project, parent.project)
    const restored = await readUmpCapture(reopened.project, variant.asset, { sourceRoot: dirname(copy), directory })
    assert.deepEqual(restored.packets, packets)
    const reexport = join(root, 'reexport'); await exportUmpCapture(reopened.project, variant.asset, reexport, { sourceRoot: dirname(copy), directory })
    for (const file of ['midi.ump.jsonl', 'session.json', 'audio.wav', 'audio-blocks.jsonl', 'original-midi.ump.jsonl', 'ump-source.json']) assert.deepEqual(await readFile(join(reexport, file)), await readFile(join(output, file)))
  } finally { await worker.terminate() }
}, rows()))

test('inward-only edits preserve the original end span in session inspection and both playback plans', () => capturedMidiFixture(async ({ root, path, imported }) => {
  const directory = join(root, 'scratch'); await mkdir(directory)
  const worker = new Worker(new URL('../arrangement-worker.mjs', import.meta.url)); let id = 0
  const options = { sourceRoot: dirname(path), directory }
  const request = async job => {
    const response = once(worker, 'message'); worker.postMessage({ ...job, id: ++id })
    const [message] = await response; assert.equal(message.ok, true, message.error); return message.result
  }
  try {
    const source = await request({ kind: 'prepare-ump', project: imported.project, asset: imported.asset, ...options })
    const editor = command(command(newUmpEditor(source.asset, source.packets), 'select-event 1:0'), 'shift-time -8000000')
    const variant = await request({ kind: 'import-ump', project: imported.project, asset: imported.asset, ump: editor.asset.ump, ...options })
    let parent = arrangementImported(arrangementEditor(imported.project), variant)
    parent = arrangementCommand(parent, `place ${variant.asset} 0`).editor
    const snapshot = await request({ kind: 'prepare-take', project: parent.project, asset: variant.asset, ...options })
    const timeline = await readCapture(snapshot.directory)
    const playback = await prepareCapturedPlayback(snapshot.directory, { directory, sourceBindings: [{ source: 'A', destination: '10' }] })
    const standalone = JSON.parse(await readFile(playback.path)).ump
    const arranged = await request({ kind: 'prepare-capture', project: parent.project, sourceBindings: [{ asset: variant.asset, source: 'A', destination: '10' }], ...options })
    const arrangement = JSON.parse(await readFile(arranged.path)).umpRegions.sources[0]
    assert.equal(timeline.midiTime.last, String(origin + 4000000n))
    assert.equal(standalone.duration, arrangement.timeline.duration); assert.equal(timeline.duration, standalone.duration)
    assert.equal(arrangement.extent, '12000001')
    const reimported = await importArrangementCapture(newArrangement(), snapshot.directory, { projectPath: join(root, 'reimport/song.json') })
    const original = await readUmpCapture(reimported.project, reimported.asset, { sourceRoot: join(root, 'reimport'), directory })
    const extended = command(command(newUmpEditor(original.asset, original.packets), 'select-event 1:0'), 'time ' + (origin + 20000000n))
    assert.equal(captureRange(extended.asset).extent, '20000001')
    const decoded = materializeUmp(original.packets, extended.asset.ump, extended.asset.parts.midi.sha256)
    assert.equal(decoded.at(-1).timestampOrigin, 'authored')
    assert.equal(decoded.at(-1).recordedHostTime, String(origin + 12000000n))
  } finally { await worker.terminate() }
}, [packet(0n, 'A', [JZZ.UMP.umpNoteOn(0, 0, 60, 1)]), packet(12000000n, 'A', [JZZ.UMP.umpNoteOff(0, 0, 60, 2)])]))
