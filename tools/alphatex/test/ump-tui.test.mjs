import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { isDeepStrictEqual } from 'node:util'
import JZZ from 'jzz'
import { newUmpEditor, umpEditorAction, umpEditorCommand } from '../ump-editor.mjs'
import { umpSourceNotes } from '../ump-source.mjs'
import { packet } from './helpers/captured-midi-fixture.mjs'
import { loadSubstituted } from './helpers/substituted-module.mjs'

const flush = () => new Promise(resolve => setImmediate(resolve))
async function controller({ preview = async () => {}, exported = async () => {} } = {}) {
  const process = { stdin: Object.assign(new EventEmitter(), { isTTY: true, isRaw: false, setRawMode(value) { this.isRaw = value }, resume() {} }),
    stdout: Object.assign(new EventEmitter(), { isTTY: true, columns: 100, rows: 24, write() {} }) }
  const asset = { name: 'Keys', parts: { midi: { sha256: 'a'.repeat(64) } } }
  const packets = [packet(0n, 'A', [JZZ.UMP.umpNoteOn(0, 0, 60, 0x9001)]), packet(100n, 'A', [JZZ.UMP.umpNoteOff(0, 0, 60, 0x1234)])]
  const substitutes = { process, isDeepStrictEqual, newUmpEditor, umpEditorAction, umpEditorCommand, safeText: String, emitKeypressEvents() {} }
  const { viewUmpEditor } = await loadSubstituted(new URL('../ump-tui.mjs', import.meta.url), substitutes)
  const abort = new AbortController()
  const done = viewUmpEditor({ asset, packets, signal: abort.signal, onPreview: preview, onExport: exported })
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
