import {MidiSourcePicker as ActualMidiSourcePicker}from '../midi-source-picker.mjs'
import {sameStepContext,stepControl}from '../step-input.mjs'
import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { EventEmitter } from 'node:events'
import { join, resolve } from 'node:path'
import { randomUUID } from 'node:crypto'
import * as editor from '../sequencer-editor.mjs'

// Exercise actual controller decisions with owned IO substitutes. No terminal
// output, layout, audio hardware or player behavior is asserted.
async function controller(options = {}) {
  const observed = { saved: [], discoveries: 0, inputs: 0 }
  const process = new EventEmitter()
  process.stdin = new EventEmitter()
  Object.assign(process.stdin, { isTTY: true, isRaw: false,
    setRawMode(value) { this.isRaw = value }, resume() {}, pause() {} })
  process.stdout = Object.assign(new EventEmitter(), { isTTY: true, columns: 80, rows: 24, write() {} })
  process.stderr = { write() {} }; process.platform = 'darwin'
  class Worker extends EventEmitter {
    postMessage() { throw new Error('Unexpected worker request') }
    async terminate() { return 0 }
  }
  class InstrumentPicker {
    constructor() { this.view = null }
    close() { this.view = null }
    async settled() {}
  }
  const slot = `sequencer-${randomUUID()}`
  globalThis[slot] = {
    process, sameStepContext, stepControl, ...editor, Worker, InstrumentPicker,
    openStepInput() { observed.inputs++; throw new Error('Unexpected input arming') },
    MidiSourcePicker: class extends ActualMidiSourcePicker {
      constructor(callbacks) {
        super({ ...callbacks, discover: ({ signal }) => {
          observed.discoveries++
          return new Promise(resolve => {
            if (signal.aborted) resolve([])
            else signal.addEventListener('abort', () => resolve([]), { once: true })
          })
        } })
        observed.sourcePicker = this
      }
    },
    defaultStateDirectory: () => '/synthetic-vst', snapshotWriter: () => async () => {},
    mkdtemp: async () => '/synthetic-temp', rm: async () => {},
    join, resolve, tmpdir: () => '/synthetic', randomUUID, emitKeypressEvents() {},
    Note: { fromMidi: String }, safeText: String,
    saveProject: async (_path, project) => { observed.saved.push(structuredClone(project)); return 'revision' },
  }
  const source = (await readFile(new URL('../sequencer-tui.mjs', import.meta.url), 'utf8'))
    .replace(/^import .*$/gm, '')
    .replace("new URL('./sequencer-worker.mjs', import.meta.url)", "new URL('file:///synthetic-worker')")

  const prefix = `const {${Object.keys(globalThis[slot]).join(',')}} = globalThis[${JSON.stringify(slot)}];\n`
  const { viewSequencer } = await import('data:text/javascript;base64,' + Buffer.from(prefix + source).toString('base64'))
  const signal = new AbortController()
  const done = viewSequencer({ root: '/synthetic', output: options.output, midiOutput: options.midiOutput,
    initialDocument: options.initialDocument, signal: signal.signal }).finally(() => { delete globalThis[slot] })
  await new Promise(resolve => setImmediate(resolve))
  const key = (name, text = '') => process.stdin.emit('keypress', text, { name })
  return { observed, done, signal, process, key,
    command(line) { key(undefined, ':'); key(undefined, line); key('return', '\r') } }
}
const flush = () => new Promise(resolve => setImmediate(resolve))


test('queued picker command retains ownership of a following Enter before dispatch',async()=>{
 const initial=editor.editorCommand(editor.newEditor(),'note C4 0 1').editor.project
 const view=await controller({initialDocument:initial})
 try {
 view.command('step-input');view.key('return');await flush()
 assert.equal(view.observed.sourcePicker.view.kind,'loading')
 view.key('escape');view.key('q');await view.done
 assert.deepEqual(view.observed.saved.at(-1),initial)
 } finally { view.signal.abort(); await view.done }
})

test('close before picker dispatch still retains its queued Enter ownership',async()=>{
 const initial=editor.editorCommand(editor.newEditor(),'note C4 0 1').editor.project
 const view=await controller({initialDocument:initial})
 try {
 view.command('step-input');view.key('return');view.signal.abort();await view.done
 assert.deepEqual(view.observed.saved.at(-1),initial)
 } finally { view.signal.abort(); await view.done }
})


test('dismiss before picker dispatch retains menu keys without starting discovery or input',async()=>{
 const initial=editor.editorCommand(editor.newEditor(),'note C4 0 1').editor.project
 const view=await controller({initialDocument:initial})
 try {
 view.command('step-input');view.key('return');view.key('escape');await flush()
 view.key('q');await view.done
 assert.equal(view.observed.discoveries,0);assert.equal(view.observed.inputs,0)
 assert.deepEqual(view.observed.saved.at(-1),initial)
 } finally { view.signal.abort(); await view.done }
})
