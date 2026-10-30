import test from 'node:test'
import assert from 'node:assert/strict'
import JZZ from 'jzz'
import { newUmpEditor, umpEditorCommand } from '../ump-editor.mjs'
import { materializeUmp } from '../ump-source.mjs'
import { packet } from './helpers/captured-midi-fixture.mjs'

const origin = 10000000000000000000n, hash = 'a'.repeat(64)
const asset = { name: 'Native rhythm', parts: { midi: { sha256: hash } }, midiTime: { first: String(origin), last: String(origin + 12000000n) },
  manifest: { sampleRate: 48000, audioFrames: '0', midiPacketCount: '4',
    clock: { numer: 125, denom: 3, requestedStart: String(origin), firstAudioHostTime: null } } }
const rows = () => [packet(0n, 'A', [JZZ.UMP.umpNoteOn(3, 5, 60, 0), JZZ.UMP.umpPnPitchBend(3, 5, 60, 0x87654321)]),
  packet(2400000n, 'B', [JZZ.UMP.umpNoteOn(9, 2, 60, 0x9001)]),
  packet(6000000n, 'A', [JZZ.UMP.umpAftertouch(3, 5, 60, 0xffffffff)]),
  packet(12000000n, 'A', [JZZ.UMP.umpNoteOff(3, 5, 60, 0xfedc)])]
const command = (editor, text) => umpEditorCommand(editor, text).editor
const times = editor => editor.events.map(event => event.hostTime)

test('selected original attacks, releases and expression move together as one native-clock history decision', () => {
  const packets = rows(), before = structuredClone(packets), initial = newUmpEditor(asset, packets, { tempo: 120 })
  const selected = command(initial, 'select-events 0:0 0:2 2:0 3:0')
  assert.equal(selected.asset, initial.asset); assert.equal(selected.undo.length, 0)
  const edited = command(selected, 'shift-events-beats 1/3')
  assert.deepEqual(times(edited), [origin + 4000000n, origin + 4000000n, origin + 2400000n, origin + 10000000n, origin + 16000000n].map(String))
  assert.equal(edited.undo.length, 1)
  assert.deepEqual(command(edited, 'undo').asset, asset)
  assert.deepEqual(command(command(edited, 'undo'), 'redo').asset, edited.asset)
  assert.deepEqual(edited.events.map(event => event.words), initial.events.map(event => event.words))
  assert.deepEqual(edited.events.map(event => [event.id, event.source, event.originalHostTime]), initial.events.map(event => [event.id, event.source, event.originalHostTime]))
  assert.deepEqual(packets, before)
  assert.deepEqual(command(edited, 'reset-event-times').asset, asset)
  assert.deepEqual(command(selected, 'deselect-events').eventSelection, [])
  assert.throws(() => command(command(selected, 'deselect-events'), 'shift-events-ticks 1'))
})

test('native stretch scales current selected distances exactly, with explicit anchors and untouched other sources', () => {
  const initial = newUmpEditor(asset, rows(), { tempo: 120 })
  const selected = command(initial, 'select-events 0:0 0:2 2:0 3:0')
  const stretched = command(selected, 'stretch-events 3/2')
  assert.deepEqual(times(stretched), [origin, origin, origin + 2400000n, origin + 9000000n, origin + 18000000n].map(String))
  const anchored = command(selected, 'stretch-events 2 1/2')
  assert.deepEqual(times(anchored), [origin - 6000000n, origin - 6000000n, origin + 2400000n, origin + 6000000n, origin + 18000000n].map(String))
  assert.equal(command(selected, 'stretch-events 1'), selected)
  const moved = command(selected, 'shift-events-seconds .125')
  assert.equal(BigInt(moved.events[0].hostTime), origin + 3000000n)
  const tied = command(command(newUmpEditor(asset, [packet(0n, 'A', [JZZ.UMP.umpNoteOn(0, 0, 60, 1), JZZ.UMP.umpNoteOff(0, 0, 60, 2)])]), 'select-events 0:2 0:0'), 'shift-events-ticks 1')
  assert.deepEqual(materializeUmp(tied.packets, tied.asset.ump, hash).flatMap(row => row.words), tied.packets[0].words)
})

test('bad identities, unsupported source clocks, nonintegral stretch and UInt64 overflow refuse the entire group', () => {
  const initial = newUmpEditor(asset, rows(), { tempo: 120 }), selected = command(initial, 'select-events 0:0 3:0')
  const before = structuredClone(selected)
  for (const line of ['select-events', 'select-events 0:0 0:0', 'select-events 0:0 0:1', 'select-events 0:0 missing',
    'shift-events-ticks 1e3', 'shift-events-ticks -10000000000000000001', 'shift-events-ticks 18446744073709551615',
    'stretch-events 0', 'stretch-events -1', 'stretch-events 1/7', 'stretch-events 1/0', 'stretch-events NaN']) assert.throws(() => command(selected, line), line)
  assert.deepEqual(selected, before)
  const packets = rows(); packets[1].words.unshift(0x00101234)
  const embedded = command(newUmpEditor(asset, packets), 'select-events 0:0 1:1')
  assert.throws(() => command(embedded, 'shift-events-ticks 1'), /[Ee]mbedded/)
  assert.equal(embedded.asset.ump, undefined)
  assert.throws(() => command(command(newUmpEditor(asset, rows()), 'select-events 0:0'), 'shift-events-beats 1'), /tempo/)
})

test('large UInt64 distances never cross binary64; value edits and navigation retain the explicit event group', () => {
  const packets = [packet(-origin, 'A', [JZZ.UMP.umpNoteOn(0, 0, 60, 1)]), packet(2n, 'A', [JZZ.UMP.umpNoteOff(0, 0, 60, 2)])]
  const initial = command(newUmpEditor(asset, packets), 'select-events 0:0 1:0')
  const stretched = command(initial, 'stretch-events 1/2')
  assert.equal(stretched.events[1].hostTime, '5000000000000000001')
  assert.throws(() => command(initial, 'stretch-events 2'))
  let edited = command(command(newUmpEditor(asset, rows(), { tempo: 120 }), 'select-events 0:0 3:0'), 'pitch-absolute 60.5')
  edited = command(command(edited, 'select-expression 0:2'), 'value32 4294967295')
  edited = command(edited, 'shift-events-ticks 1')
  assert.deepEqual(edited.eventSelection, ['0:0', '3:0'])
  assert.equal(edited.notes[0].pitch, 30976); assert.equal(edited.expressions[0].value, 0xffffffff)
  assert.equal(edited.expressions[0].hostTime, String(origin))
})
