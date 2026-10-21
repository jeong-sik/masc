import test from 'node:test'
import assert from 'node:assert/strict'
import JZZ from 'jzz'
import { absoluteUmpPitch, materializeUmp, umpSourceNotes, editUmpNotes, umpOnsetHarmony } from '../ump-source.mjs'
import { newUmpEditor, umpEditorCommand } from '../ump-editor.mjs'
import { CaptureTimeline } from '../session-data.mjs'
import { packet } from './helpers/captured-midi-fixture.mjs'

const hash = 'a'.repeat(64), asset = { name: 'Original', parts: { midi: { sha256: hash } } }
const rows = () => [packet(0n, 'keys', [JZZ.UMP.umpPnRPN(3, 5, 60, 3, 0x7b123456), JZZ.UMP.umpPnPitchBend(3, 5, 60, 0x87654321),
  ...[60, 64, 67, 71].map(key => JZZ.UMP.umpNoteOn(3, 5, key, 0x9001))]),
  packet(1n, 'other', [JZZ.UMP.umpNoteOn(3, 5, 60, 0)]),
  packet(2n, 'keys', [JZZ.UMP.umpAftertouch(3, 5, 60, 0xabcdef01)]),
  packet(3n, 'keys', [JZZ.UMP.umpNoteOff(3, 5, 60, 0x1234), JZZ.UMP([0x43, 0xf5, 60, 3, 0, 0, 0, 0])]),
  { ...packet(4n, 'keys', []), words: [0x50000000, 0x12345678, 0xabcdef01, 0x87654321, 0xf0000000, 1, 2, 3] }]

test('native absolute pitch/zero velocity edits keep Note Index, PN32, Off dynamics, opaque words and original host identities', () => {
  const packets = rows(), original = structuredClone(packets), notes = umpSourceNotes(packets, undefined, hash)
  assert.equal(notes[4].velocity, 0)
  const changed = editUmpNotes(packets, undefined, hash, [{ kind: 'note', id: notes[0].id, pitch: absoluteUmpPitch('60.5'), velocity: 0 }])
  const result = materializeUmp(packets, changed, hash)
  assert.deepEqual(packets, original)
  assert.deepEqual(result[0].words, [0x43053c03, 0x7b123456, 0x43653c00, 0x87654321, 0x43953c03, 0x00007900,
    ...original[0].words.slice(6)])
  assert.deepEqual(result.slice(1), original.slice(1))
  assert.deepEqual(result.map(({ words, ...identity }) => identity), original.map(({ words, ...identity }) => identity))
  assert.deepEqual(umpSourceNotes(packets, changed, hash)[0].pitch, 30976)
})

test('exact-onset native revoice changes one atomic revision and retains source scopes and every raw voice address', () => {
  const packets = rows(); let editor = newUmpEditor(asset, packets)
  assert.equal(umpEditorCommand(editor, 'export /music/My  native take').effect.path, '/music/My  native take')
  assert.equal(umpOnsetHarmony(editor.notes, editor.selected).kind, 'key-index-candidates')
  editor = umpEditorCommand(editor, 'revoice Cmaj7 drop2').editor
  assert.deepEqual(editor.notes.slice(0, 4).map(note => note.pitch / 512), [55, 60, 64, 71])
  assert.deepEqual(editor.notes.slice(0, 4).map(note => note.index), [60, 64, 67, 71])
  assert.ok(editor.notes.slice(0, 4).every(note => note.velocity === 0x9001))
  assert.equal(editor.notes[4].attribute, 0); assert.equal(editor.undo.length, 1)
  assert.equal(umpOnsetHarmony(editor.notes, editor.selected).kind, 'absolute-attribute')
  assert.ok(umpOnsetHarmony(editor.notes, editor.selected).candidates.includes('Cmaj7/G'))
  const revised = editor.asset
  editor = umpEditorCommand(editor, 'undo').editor; assert.equal(editor.asset, asset)
  editor = umpEditorCommand(editor, 'redo').editor; assert.equal(editor.asset, revised)
  const before = editor
  assert.throws(() => umpEditorCommand(editor, 'revoice C close'), /voice count/)
  assert.equal(editor, before)
})

test('fractional pitches remain exact and raw vendor/Profile attributes remain editable without implicit absolute override', () => {
  const packets = [packet(0n, 'keys', [JZZ.UMP.umpNoteOn(0, 0, 60, 0x1234, 3, 60 * 512 + 1),
    JZZ.UMP.umpNoteOn(0, 1, 64, 0x5678, 1, 0xabcd)])]
  const notes = umpSourceNotes(packets, undefined, hash)
  assert.equal(umpOnsetHarmony(notes, notes[0].id).kind, 'fractional-pitch')
  assert.equal(umpOnsetHarmony(notes, notes[1].id).kind, 'opaque-attribute')
  assert.throws(() => editUmpNotes(packets, undefined, hash, [{ kind: 'note', id: notes[1].id, pitch: 60 * 512 }]), /overwrite/)
  const edits = editUmpNotes(packets, undefined, hash, [{ kind: 'note', id: notes[1].id, velocity: 65535 }])
  assert.deepEqual(materializeUmp(packets, edits, hash)[0].words, [0x40903c03, 0x12347801, 0x40914001, 0xffffabcd])
  for (const value of ['0', '60.5', '60.001953125', '127.998046875']) assert.ok(Number.isInteger(absoluteUmpPitch(value)))
  for (const value of ['60.1', '128', '-1', 'NaN']) assert.throws(() => absoluteUmpPitch(value))
})

test('stale hashes, duplicate decisions, non-boundary offsets, malformed overlays and overflow refuse whole candidates', () => {
  const packets = rows(), valid = { schemaVersion: 1, midiSha256: hash, notes: [{ packet: 0, word: 4, pitch: 30000 }] }
  for (const edits of [{ ...valid, midiSha256: 'b'.repeat(64) }, { ...valid, extra: true },
    { ...valid, notes: [...valid.notes, ...valid.notes] }, { ...valid, notes: [{ packet: 0, word: 5, velocity: 1 }] },
    { ...valid, notes: [{ packet: 0, word: 0, pitch: 1 }] }, { ...valid, notes: [{ packet: 0, word: 4, pitch: 65536 }] }]) {
    assert.throws(() => materializeUmp(packets, edits, hash))
  }
  assert.throws(() => editUmpNotes(packets, undefined, hash, [{ kind: 'note', id: '0:4', velocity: 1 }, { kind: 'note', id: '0:4', velocity: 2 }]))
})

test('captured waveform/note inspection displays absolute Pitch7.9 while pairing the Off by unchanged Note Index', () => {
  const manifest = { schemaVersion: 1, state: 'recorded', sampleRate: 48000, channels: 1,
    clock: { kind: 'mach-host-time', requestedStart: '10000000000000000000', numer: 125, denom: 3 }, midiSources: [{ id: 'keys', name: 'Keys' }] }
  const timeline = new CaptureTimeline(manifest)
  timeline.addMidi(packet(0n, 'keys', [JZZ.UMP.umpNoteOn(0, 0, 17, 0, 3, 60 * 512 + 256)]))
  timeline.addMidi(packet(100n, 'keys', [JZZ.UMP.umpNoteOff(0, 0, 17, 0x1234)]))
  const note = [...timeline.midi.values()][0].notes[0]
  assert.equal(note.pitch, 60.5); assert.equal(note.end, timeline.seconds('10000000000000000100'))
})
