import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { isDeepStrictEqual } from 'node:util'
import JZZ from 'jzz'
import { newUmpEditor, umpEditorRows, umpEditorAction, umpEditorCommand } from '../ump-editor.mjs'
import { umpSourceNotes } from '../ump-source.mjs'
import { captureSecondsAtHost } from '../capture-time.mjs'
import { packet } from './helpers/captured-midi-fixture.mjs'
import { loadSubstituted } from './helpers/substituted-module.mjs'

const flush = () => new Promise(resolve => setImmediate(resolve))
async function controller({ preview = async () => {}, exported = async () => {}, captured, tempo } = {}) {
  const process = { stdin: Object.assign(new EventEmitter(), { isTTY: true, isRaw: false, setRawMode(value) { this.isRaw = value }, resume() {} }),
    stdout: Object.assign(new EventEmitter(), { isTTY: true, columns: 100, rows: 24, write() {} }) }
  const asset = { name: 'Keys', parts: { midi: { sha256: 'a'.repeat(64) } }, midiTime: { first: '10000000000000000000', last: '10000000000000000100' },
    manifest: { sampleRate: 48000, audioFrames: '0', midiPacketCount: '2', clock: { kind: 'mach-host-time', numer: 125, denom: 3,
      requestedStart: '10000000000000000000', firstAudioHostTime: null } } }
  const packets = captured ?? [packet(0n, 'A', [JZZ.UMP.umpNoteOn(0, 0, 60, 0x9001)]), packet(100n, 'A', [JZZ.UMP.umpNoteOff(0, 0, 60, 0x1234)])]
  const substitutes = { isDeepStrictEqual, newUmpEditor, umpEditorRows, umpEditorAction, umpEditorCommand, captureSecondsAtHost, safeText: String, emitKeypressEvents() {} }
  const { viewUmpEditor } = await loadSubstituted(new URL('../ump-tui.mjs', import.meta.url), substitutes, { globals: { process } })
  const abort = new AbortController()
  const done = viewUmpEditor({ asset, packets, tempo, signal: abort.signal, onPreview: preview, onExport: exported })
  const key = (name, text = '', extra = {}) => process.stdin.emit('keypress', text, { name, ...extra })
  return { asset, packets, done, abort, process, key, command(line) { key(undefined, ':'); key(undefined, line); key('return') } }
}

test('owned UMP controller drains admitted note edits before return and exports the same immutable overlay', async () => {
  let finishExport
  const exported = new Promise(resolve => { finishExport = resolve })
  const exports = [], view = await controller({ exported: async asset => { exports.push(asset); finishExport() } })
  view.command('pitch-absolute 60.5'); view.command('velocity 0'); view.command('export /unused/output')
  await exported; view.key('q')
  const result = await view.done
  assert.equal(result.changed, true)
  const notes = umpSourceNotes(view.packets, result.asset.ump, result.asset.parts.midi.sha256)
  assert.equal(notes[0].pitch, 30976); assert.equal(notes[0].velocity, 0)
  assert.equal(exports.length, 1); assert.deepEqual(exports[0].ump, result.asset.ump)
  assert.equal(view.process.stdin.isRaw, false)
})

test('q remains actionable during UMP preview preparation and joins its cancellation before returning', async () => {
  let entered, retired = false
  const ready = new Promise(resolve => { entered = resolve })
  const view = await controller({ preview: async (asset, signal) => {
    entered(signal)
    await new Promise(resolve => signal.addEventListener('abort', () => { retired = true; resolve() }, { once: true }))
  } })
  view.command('pitch-absolute 62'); view.command('play')
  const signal = await ready; view.key('q')
  const result = await view.done
  assert.equal(signal.aborted, true); assert.equal(retired, true); assert.equal(result.changed, true)
  assert.equal(view.process.stdin.listenerCount('keypress'), 0)
})

test('external abort cancels a borrowed native session and never returns an adoptable late variant', async () => {
  let entered, retired = false
  const ready = new Promise(resolve => { entered = resolve })
  const view = await controller({ preview: async (asset, signal, borrow) => borrow(async () => {
    entered(signal)
    await new Promise(resolve => signal.addEventListener('abort', () => { retired = true; resolve() }, { once: true }))
  }) })
  view.command('pitch-absolute 64'); view.command('play')
  await ready; view.abort.abort(); await flush()
  const result = await view.done
  assert.equal(retired, true); assert.equal(result.changed, false)
  assert.equal(view.process.stdin.listenerCount('keypress'), 0)
})

test('owned controller exports mixed expression/note edits and returns the same variant after Tab navigation', async () => {
  let finishExport
  const exported = new Promise(resolve => { finishExport = resolve }), exports = []
  const view = await controller({ captured: [packet(0n, 'A', [JZZ.UMP.umpNoteOn(0, 0, 60, 0x9001),
    JZZ.UMP.umpPnPitchBend(0, 0, 60, 0x87654321), JZZ.UMP.umpAftertouch(0, 0, 60, 0x12345678)])],
  exported: async asset => { exports.push(asset); finishExport() } })
  view.key('tab'); view.command('value32 2147483648'); view.key('down'); view.command('value32 4294967295')
  view.key('tab'); view.command('pitch-absolute 60.5'); view.command('export /unused/output')
  await exported; view.key('q'); const result = await view.done
  assert.equal(result.changed, true); assert.deepEqual(exports[0].ump, result.asset.ump)
  assert.deepEqual(result.asset.ump.notes, [{ packet: 0, word: 0, pitch: 30976 }])
  assert.deepEqual(result.asset.ump.expressions, [{ packet: 0, word: 2, value: 2147483648 }, { packet: 0, word: 4, value: 4294967295 }])
  assert.equal(view.process.stdin.isRaw, false); assert.equal(view.process.stdin.listenerCount('keypress'), 0)
})

test('owned controller keeps original identities through event time edits, undo and explicit release duration', async () => {
  let finishExport
  const exported = new Promise(resolve => { finishExport = resolve }), exports = []
  const view = await controller({ exported: async asset => { exports.push(asset); finishExport() } })
  view.command('shift-time 1'); view.command('duration-ticks 1:0 200')
  view.command('select-event 1:0'); view.command('shift-time 10'); view.command('undo')
  view.command('export /unused/time-output'); await exported; view.key('q')
  const result = await view.done
  assert.equal(result.changed, true); assert.deepEqual(result.asset.ump, exports[0].ump)
  assert.deepEqual(result.asset.ump.timing, [{ packet: 0, word: 0, hostTime: '10000000000000000001' },
    { packet: 1, word: 0, hostTime: '10000000000000000201' }])
  assert.equal(view.process.stdin.listenerCount('keypress'), 0); assert.equal(view.process.stdin.isRaw, false)
})

test('owned controller exports decimal seconds as exact native ticks and drains its history before return', async () => {
  let finishExport
  const exported = new Promise(resolve => { finishExport = resolve }), exports = []
  const view = await controller({ exported: async asset => { exports.push(asset); finishExport() } })
  view.command('note-seconds 1:0 .1 .25'); view.command('select-event 1:0'); view.command('shift-seconds -.125')
  view.command('undo'); view.command('clock'); view.command('export /unused/decimal-output')
  await exported; view.key('q'); const result = await view.done
  assert.equal(result.changed, true); assert.deepEqual(exports[0].ump, result.asset.ump)
  assert.deepEqual(result.asset.ump.timing, [{ packet: 0, word: 0, hostTime: '10000000000002400000' },
    { packet: 1, word: 0, hostTime: '10000000000006000000' }])
  assert.equal(view.process.stdin.listenerCount('keypress'), 0); assert.equal(view.process.stdin.isRaw, false)
})

test('owned controller uses the supplied project tempo for fractional beats and exports exact native times', async () => {
  let finishExport
  const exported = new Promise(resolve => { finishExport = resolve }), exports = []
  const view = await controller({ tempo: 120, exported: async asset => { exports.push(asset); finishExport() } })
  view.command('note-beats 1:0 1/3 2/3'); view.command('select-event 1:0'); view.command('shift-beats -1/6')
  view.command('undo'); view.command('export /unused/beat-output'); await exported; view.key('q')
  const result = await view.done
  assert.equal(result.changed, true); assert.deepEqual(exports[0].ump, result.asset.ump)
  assert.deepEqual(result.asset.ump.timing, [{ packet: 0, word: 0, hostTime: '10000000000004000000' },
    { packet: 1, word: 0, hostTime: '10000000000008000000' }])
  assert.equal(view.process.stdin.isRaw, false); assert.equal(view.process.stdin.listenerCount('keypress'), 0)
})


test('owned controller drains explicit grouped rhythm edits, history and the matching export before return', async () => {
  let finishExport
  const exported = new Promise(resolve => { finishExport = resolve }), exports = []
  const view = await controller({ tempo: 120, exported: async asset => { exports.push(asset); finishExport() } })
  view.command('select-events 0:0 1:0'); view.command('shift-events-beats 1/3')
  view.command('stretch-events 2'); view.command('undo'); view.command('redo')
  view.command('export /unused/group-output'); await exported; view.key('q')
  const result = await view.done
  assert.equal(result.changed, true); assert.deepEqual(result.asset.ump, exports[0].ump)
  assert.deepEqual(result.asset.ump.timing, [{ packet: 0, word: 0, hostTime: '10000000000004000000' },
    { packet: 1, word: 0, hostTime: '10000000000004000200' }])
  assert.deepEqual(view.packets.map(row => row.hostTime), ['10000000000000000000', '10000000000000000100'])
  assert.equal(view.process.stdin.listenerCount('keypress'), 0); assert.equal(view.process.stdin.isRaw, false)
})
