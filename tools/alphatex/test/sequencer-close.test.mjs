import { StatusReader } from '../status-reader.mjs'
import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { EventEmitter } from 'node:events'
import { join, resolve, dirname } from 'node:path'
import { randomUUID, createHash } from 'node:crypto'
import { constants } from 'node:fs'
import { arrangementRoute, selectArrangementRoute } from '../arrangement-playback.mjs'
import { arrangementFromPhrase, arrangementFromMidiSource } from '../phrase-arrangement.mjs'
import * as editor from '../sequencer-editor.mjs'
import { sourceExpressions, selectedExpression, sourceTempos, selectedTempo } from '../midi-source-editor.mjs'
import { importMidiSource, midiSourcePattern } from '../midi-source.mjs'
import { harmonyAt, PPQ, GM_DRUM_CHANNEL } from '../sequencer-project.mjs'
import { MidiSourcePicker as SourcePicker } from '../midi-source-picker.mjs'
import { sourceSecondsAtTick, sourceTickAtSeconds } from '../midi-source-playback.mjs'
import { isFluidSound } from '../soundfont.mjs'
import { pickerFooter, selectionLabel } from '../instruments.mjs'

const frozenSound = selection => ({ kind: 'vst', selection, instrument: { identifier: 'Bass', version: '1' },
  preset: { data: Buffer.from('frozen state').toString('base64'), sha256: createHash('sha256').update('frozen state').digest('hex') } })

// Exercise actual controller decisions with owned IO substitutes. No terminal
// output, layout, audio hardware or player behavior is asserted.
async function controller(options = {}) {
  const observed = { saved: [], workers: [], writes: [], copies: [], sessions: 0, players: 0, arrangements: [], pickers: [], native: [], snapshots: [], soundCaptures: [] }
  const process = new EventEmitter()
  process.stdin = new EventEmitter()
  Object.assign(process.stdin, { isTTY: true, isRaw: false,
    setRawMode(value) { this.isRaw = value }, resume() {}, pause() {} })
  process.stdout = Object.assign(new EventEmitter(), { isTTY: true, columns: 80, rows: 24, write() {} })
  process.stderr = { write() {} }; process.platform = 'darwin'
  class Worker extends EventEmitter {
    constructor() { super(); this.requests = []; this.terminated = false; observed.workers.push(this) }
    postMessage(job) { this.requests.push(job) }
    async terminate() { this.terminated = true; return 0 }
  }
  class InstrumentPicker {
    constructor(callbacks) { Object.assign(this, callbacks); this.view = null; observed.pickers.push(this) }
    open() {
      this.view = { kind: 'plugins', cursor: 0, query: '' }
      if (options.autoSoundfont !== false) { this.close(); this.soundfont() }
    }
    close() { this.view = null }
    items() { return [] }
    async settled() {}
    async keypress(_text, key) { if (key.name === 'escape') this.close() }
  }
  class MidiSourcePicker extends SourcePicker {
    constructor(callbacks) {
      super({ ...callbacks, discover: async () => { throw new Error('Unexpected MIDI source discovery') } })
    }
  }
  const slot = `sequencer-${randomUUID()}`
  globalThis[slot] = { StatusReader,
    process, InstrumentPicker, MidiSourcePicker, pickerFooter, selectionLabel, defaultStateDirectory: () => '/synthetic-vst',
    snapshotWriter: () => async value => { observed.snapshots.push(value) },
    captureVstSound(selection) { observed.soundCaptures.push(selection); return options.capture?.(selection) ?? { promise: Promise.resolve(frozenSound(selection)), cancel() {} } },
    renderVstPhrase(value) { observed.native.push(value); return options.native(value) },
    isFluidSound, GM_DRUM_CHANNEL,
    captureFluidSound() { throw new Error('Unexpected FluidSynth selection') },
    renderFluidSound() { throw new Error('Unexpected FluidSynth render') },
    mkdtemp: async () => '/synthetic-temp', rm: async () => {},
    writeFile: async path => { observed.writes.push(path) },
    copyFile: async (from, to) => { observed.copies.push([from, to]) },
    arrangementRoute, selectArrangementRoute, dirname, constants, join, resolve, tmpdir: () => '/synthetic', randomUUID, emitKeypressEvents() {},
    openPlayback(value) { observed.players++; if (options.playback) return options.playback(value); throw new Error('Unexpected playback') }, Worker,
    Note: { fromMidi: String }, ...editor, harmonyAt, PPQ, sourceExpressions, selectedExpression, sourceTempos, selectedTempo, sourceSecondsAtTick, sourceTickAtSeconds,
    loadProject: async () => { throw new Error('Unexpected load') },
    saveProject: async (path, project) => { observed.saved.push(structuredClone(project)); return 'revision' },
    projectMidi() { throw new Error('Unexpected MIDI export') }, safeText: String,
    async openArrangement(value) { observed.arrangements.push(value); await options.arrangement?.(value) },
    async openSession(value) { observed.sessions++; await options.session?.(value) },
  }
  const source = (await readFile(new URL('../sequencer-tui.mjs', import.meta.url), 'utf8'))
    .replace(/^import .*$/gm, '')
    .replace("new URL('./sequencer-worker.mjs', import.meta.url)", "new URL('file:///synthetic-worker')")
    .replace("await import('./music-session.mjs')", 'await Promise.resolve({ viewSession: openSession })')
    .replaceAll("await import('./arrangement-tui.mjs')", 'await Promise.resolve({ viewArrangement: openArrangement })')
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
const pitches = value => value.observed.saved.at(-1).tracks[0].notes.map(note => note.pitch)

test('terminal note selection shortcuts copy across tracks and move the whole selected phrase', async () => {
  let initial = editor.newEditor()
  for(const line of ['note C4 0 1','note E4 1 1'])initial=editor.editorCommand(initial,line).editor
  const view=await controller({initialDocument:initial.project})
  const modifiedKey=(name,modifiers)=>view.process.stdin.emit('keypress','',{name,...modifiers})
  modifiedKey('a',{ctrl:true});modifiedKey('c',{meta:true})
  view.command('track-add Variation');view.command('cursor 4 C4')
  modifiedKey('v',{meta:true});modifiedKey('right',{shift:true})
  await flush();view.key('q');await view.done
  const saved=view.observed.saved.at(-1)
  assert.deepEqual(saved.tracks[0],initial.project.tracks[0])
  assert.deepEqual(saved.tracks[1].notes.map(note=>[note.pitch,note.start]),[[60,4.25*PPQ],[64,5.25*PPQ]])
})

test('admitted clipboard edits drain into close and Escape clears a selection without exiting the editor', async () => {
  const initial=editor.editorCommand(editor.newEditor(),'note C4 0 1').editor.project
  const view=await controller({initialDocument:initial})
  view.command('select-all');await flush();view.key('escape');await flush()
  view.key('return');await flush() // Selection was cleared; remove the cursor note.
  view.command('undo');view.command('select-all');view.command('copy-notes');view.command('paste-notes 4')
  view.signal.abort();await view.done
  assert.deepEqual(view.observed.saved.at(-1).tracks[0].notes.map(note=>[note.pitch,note.start]),[[60,0],[60,4*PPQ]])
})

test('the x key removes the selected note group in one undoable decision', async () => {
  let initial=editor.newEditor()
  for(const line of ['note C4 0 1','note E4 1 1'])initial=editor.editorCommand(initial,line).editor
  const view=await controller({initialDocument:initial.project})
  view.command('select-all');view.key('x');await flush();view.key('q');await view.done
  assert.deepEqual(view.observed.saved.at(-1).tracks[0].notes,[])
})

test('analysis owns note keys, then selecting an interval returns to the intended voicing edit', async () => {
  let initial = editor.newEditor()
  for (const line of ['chord Cmaj7 0 4','chord Dm7 4 4']) initial = editor.editorCommand(initial,line).editor
  const view = await controller({initialDocument:initial.project})
  view.command('harmony track'); view.key('delete'); await flush()
  const worker = view.observed.workers[0], job = worker.requests[0]
  assert.deepEqual(job.options.scope,{kind:'track',id:'track-1'})
  worker.emit('message',{id:job.id,ok:true,result:{rows:[{kind:'span',start:0,end:4*PPQ,pitches:[60,64,67,71],notes:[],candidates:[]},
    {kind:'span',start:4*PPQ,end:8*PPQ,pitches:[62,65,69,72],notes:[],candidates:[]}]}})
  await flush();view.key('down');view.key('return');view.command('revoice Dm7 drop2 4');await flush()
  view.key('q');await view.done
  assert.deepEqual(pitches(view),[60,64,67,71,57,62,65,72])
})

test('a changed draft cancels analysis and its late result cannot take ownership of subsequent note input', async () => {
  const initial = editor.editorCommand(editor.newEditor(),'note C4 0 1').editor.project
  const view = await controller({initialDocument:initial})
  view.command('harmony');await flush()
  const worker = view.observed.workers[0], job = worker.requests[0]
  view.command('transpose 12');await flush()
  assert.equal(Atomics.load(new Int32Array(job.cancel),0),1)
  worker.emit('message',{id:job.id,ok:true,result:{rows:[{kind:'span',start:0,end:PPQ,pitches:[60],notes:[],candidates:[]}]}})
  await flush();view.key('return');view.key('q');await view.done
  assert.deepEqual(pitches(view),[72,60])
})

test('closing a ready analysis does not reinterpret its queued Enter as a note insertion or removal', async () => {
  const initial = editor.editorCommand(editor.newEditor(),'note C4 0 1').editor.project
  const view = await controller({initialDocument:initial})
  view.command('harmony');await flush()
  const worker = view.observed.workers[0], job = worker.requests[0]
  worker.emit('message',{id:job.id,ok:true,result:{rows:[{kind:'span',start:0,end:PPQ,pitches:[60],notes:[],candidates:[]}]}})
  await flush();view.key('return');view.signal.abort();await view.done
  assert.deepEqual(view.observed.saved.at(-1),initial)
  assert.equal(worker.terminated,true)
})

test('closing before an admitted analysis starts retains ownership of its queued note keys', async () => {
  const initial = editor.editorCommand(editor.newEditor(),'note C4 0 1').editor.project
  const view = await controller({initialDocument:initial})
  view.command('harmony');view.key('return');view.signal.abort();await view.done
  assert.deepEqual(view.observed.saved.at(-1),initial)
  assert.equal(view.observed.workers[0].requests.length,0)
})

test('an admitted analysis export drains on close while retaining the original musical document', async () => {
  const initial = editor.editorCommand(editor.newEditor(),'note C4 0 1').editor.project
  const view = await controller({initialDocument:initial})
  view.command('harmony');await flush()
  const worker = view.observed.workers[0], job = worker.requests[0]
  worker.emit('message',{id:job.id,ok:true,result:{rows:[{kind:'span',start:0,end:PPQ,pitches:[60],notes:['C4'],candidates:[]}]}})
  await flush();view.command('harmony-export /analysis.json');view.signal.abort();await view.done
  assert.ok(view.observed.writes.includes('/analysis.json'))
  assert.deepEqual(view.observed.saved.at(-1),initial)
})

for (const opening of ['shortcut', 'command']) {
  test(`open phrase status owns edit, save, record and playback keys (${opening})`, async () => {
    const view = await controller()
    try {
      view.command('title Retained before reading'); await flush()
      const before = {
        saved: view.observed.saved.length,
        workers: view.observed.workers.map(worker => worker.requests.length),
      }
      if (opening === 'shortcut') view.key(undefined, '!')
      else view.command('status')

      for (const name of ['s', 'space', 'r', 'up', 'down', 'pageup', 'pagedown', 'home', 'end']) view.key(name)
      view.key(undefined, ':')
      view.key(undefined, 'title Must not be admitted')
      await flush()
      assert.equal(view.observed.saved.length, before.saved)
      assert.equal(view.observed.players, 0)
      assert.deepEqual(view.observed.workers.map(worker => worker.requests.length), before.workers)
      assert.equal(view.observed.native.length, 0)
      assert.equal(view.observed.soundCaptures.length, 0)
      assert.equal(view.observed.sessions, 0)

      view.key('return'); view.command('save'); await flush()
      assert.equal(view.observed.saved.at(-1).title, 'Retained before reading')
      view.command('title Edited after reading'); view.command('save'); await flush()
      assert.equal(view.observed.saved.at(-1).title, 'Edited after reading')
    } finally {
      view.signal.abort()
      await view.done
    }
  })
}

test('reopened document auditions its frozen sound without consulting the picker', async () => {
  const selection = { plugin_path: '/synth.vst3', plugin_name: null, preset_path: '/removed.vstpreset', name: 'Bass' }
  const document = editor.editorSound(editor.editorCommand(editor.newEditor(), 'note C4 0 1').editor, frozenSound(selection)).project
  const view = await controller({ initialDocument: document, autoSoundfont: false,
    native: ({ preparation }) => ({ promise: preparation.promise, cancel() {} }) })
  view.key('space'); await flush()
  assert.equal(view.observed.soundCaptures.length, 0); assert.equal(view.observed.pickers[0].view, null)
  assert.deepEqual(view.observed.native[0].sound, document.sound)
  view.key('q'); await view.done
  assert.deepEqual(view.observed.saved.at(-1).sound, document.sound)
})

test('closing during sound capture waits for child closure and refuses late adoption/playback', async () => {
  let complete, cancels = 0
  const selection = { plugin_path: '/synth.vst3', plugin_name: null, preset_path: null, name: 'Bass' }
  const view = await controller({ autoSoundfont: false, capture() {
    return { promise: new Promise(resolve => { complete = resolve }), cancel() { cancels++ } }
  } })
  view.key('return'); view.key('i'); await flush()
  view.observed.pickers[0].close(); view.observed.pickers[0].selected(selection); await flush()
  let closed = false; view.done.then(() => { closed = true })
  view.key('q'); await flush()
  assert.equal(cancels, 1); assert.equal(closed, false)
  complete(frozenSound(selection)); await view.done
  assert.equal(view.observed.saved.at(-1).sound, undefined)
  assert.equal(view.observed.native.length, 0); assert.equal(view.observed.players, 0)
})

test('stop and MIDI route selection retire a pending snapshot while editor decisions remain live', async () => {
  let complete, cancels = 0
  const selection = { plugin_path: '/synth.vst3', plugin_name: null, preset_path: null, name: 'Bass' }
  const view = await controller({ autoSoundfont: false, capture() {
    return { promise: new Promise(resolve => { complete = resolve }), cancel() { cancels++ } }
  } })
  view.key('return'); view.key('i'); await flush()
  view.observed.pickers[0].close(); view.observed.pickers[0].selected(selection); await flush()
  view.command('stop'); view.command('midi-output -123'); view.key('up'); view.key('return'); view.key('s'); await flush()
  assert.equal(cancels, 1); assert.deepEqual(pitches(view), [60, 61])
  complete(frozenSound(selection)); await flush()
  view.command('play'); await flush()
  const request = view.observed.workers[0].requests.at(-1)
  assert.equal(request.options.format, 'midi'); assert.equal(request.options.midiOutput, '-123')
  assert.equal(request.project.sound, undefined); assert.equal(view.observed.native.length, 0)
  view.key('q'); await view.done
})

test('preview failure after sound adoption does not discard the next admitted edit', async () => {
  let complete
  const selection = { plugin_path: '/synth.vst3', plugin_name: null, preset_path: null, name: 'Bass' }
  const view = await controller({ autoSoundfont: false, capture() {
    return { promise: new Promise(resolve => { complete = resolve }), cancel() {} }
  } })
  view.key('return'); view.key('i'); await flush()
  view.observed.pickers[0].close(); view.observed.pickers[0].selected(selection); await flush()
  view.observed.workers[0].emit('error', new Error('worker failed during snapshot'))
  complete(frozenSound(selection)); await flush()
  view.command('title Admitted after preview failure'); view.key('q'); await view.done
  assert.equal(view.observed.saved.at(-1).title, 'Admitted after preview failure')
  assert.deepEqual(view.observed.saved.at(-1).sound, frozenSound(selection))
  assert.equal(view.observed.players, 0)
})

test('edits, undo, loop and Space keep a pending sound capture for adoption', async () => {
  let complete, cancels = 0
  const lead = { plugin_path: '/lead.vst3', plugin_name: null, preset_path: null, name: 'Lead' }
  const bass = { plugin_path: '/bass.vst3', plugin_name: null, preset_path: null, name: 'Bass' }
  const document = editor.editorSound(editor.editorCommand(editor.newEditor(), 'note C4 0 1').editor, frozenSound(lead)).project
  const view = await controller({ initialDocument: document, autoSoundfont: false,
    capture() { return { promise: new Promise(resolve => { complete = resolve }), cancel() { cancels++ } } },
    native: ({ preparation }) => ({ promise: preparation.promise, cancel() {} }) })
  view.key('i'); await flush()
  view.observed.pickers[0].close(); view.observed.pickers[0].selected(bass); await flush()
  for (const name of ['up', 'return', 'u', 'l', 'space', 'space']) view.key(name)
  view.command('title Edited during capture'); await flush()
  complete(frozenSound(bass)); await flush()
  view.key('q'); await view.done
  assert.deepEqual(view.observed.saved.at(-1).sound, frozenSound(bass)); assert.equal(cancels, 0)
  assert.deepEqual(view.observed.native.map(row => row.sound), [frozenSound(lead), frozenSound(bass)])
  assert.equal(view.observed.saved.at(-1).title, 'Edited during capture'); assert.deepEqual(pitches(view), [60])
})

test('adopting a captured sound replaces a playing preview of the previous sound', async () => {
  let complete
  const lead = { plugin_path: '/lead.vst3', plugin_name: null, preset_path: null, name: 'Lead' }
  const bass = { plugin_path: '/bass.vst3', plugin_name: null, preset_path: null, name: 'Bass' }
  const document = editor.editorSound(editor.editorCommand(editor.newEditor(), 'note C4 0 1').editor, frozenSound(lead)).project
  const requests = [], calls = []
  const view = await controller({ initialDocument: document, autoSoundfont: false,
    capture() { return { promise: new Promise(resolve => { complete = resolve }), cancel() {} } },
    native: ({ preparation, selection }) => ({ cancel() {}, promise: preparation.promise.then(() => ({ path: `/synthetic/${selection.name}.wav`,
      duration: 1, phraseDuration: 1, vst: { output_path: `/synthetic/${selection.name}.wav` }, selection })) }),
    playback(request) {
      requests.push(request)
      let finish; const completion = new Promise(resolve => { finish = resolve })
      return { ready: Promise.resolve(), completion, status() {}, pause() { calls.push('pause') },
        resume() { calls.push('resume') }, stop() { calls.push('stop') }, terminate() { finish() } }
    } })
  view.key('i'); await flush()
  view.observed.pickers[0].close(); view.observed.pickers[0].selected(bass); await flush()
  view.key('space'); await flush()
  const worker = view.observed.workers[0], job = worker.requests[0]
  worker.emit('message', { id: job.id, ok: true, result: { path: job.path } }); await flush()
  requests[0].onEvent({ kind: 'playing', currentTime: 0, duration: 1 })
  complete(frozenSound(bass)); await flush()
  const adopted = [...calls]
  view.key('q'); await view.done
  assert.deepEqual(adopted, ['stop'])
  assert.deepEqual(view.observed.native.map(row => row.sound), [frozenSound(lead), frozenSound(bass)])
  assert.deepEqual(view.observed.snapshots.find(row => row.state === 'stop_requested').selection, lead)
})

test('close drains admitted note edits and refuses keys arriving after close', async () => {
  const view = await controller()
  for (const name of ['return', 'up', 'return', 'q', 'up', 'return']) view.key(name)
  await view.done
  assert.deepEqual(pitches(view), [60, 61])
  assert.equal(view.process.stdin.isRaw, false)
  assert.ok(view.observed.workers.every(worker => worker.terminated))
})

test('accepted editor decisions drain without starting queued recording, preview or WAV export', async () => {
  const view = await controller()
  view.key('return')
  view.command('wave /synthetic/export.wav')
  view.command('record')
  view.key('space'); view.key('up'); view.key('return'); view.key('q')
  await view.done
  assert.deepEqual(pitches(view), [60, 61])
  assert.equal(view.observed.sessions, 0)
  assert.equal(view.observed.players, 0)
  assert.equal(view.observed.workers.flatMap(worker => worker.requests).length, 0)
  assert.deepEqual(view.observed.copies, [])
})

test('close cancels a pending WAV job before draining edits waiting behind it', async () => {
  const view = await controller()
  view.key('return'); view.key('space'); await flush()
  view.command('stop'); view.command('wave /synthetic/export.wav')
  await flush()
  const job = view.observed.workers[0].requests.at(-1)
  assert.ok(job)
  view.key('up'); view.key('return'); view.key('q')
  await view.done
  assert.equal(Atomics.load(new Int32Array(job.cancel), 0), 1)
  assert.deepEqual(pitches(view), [60, 61])
  assert.deepEqual(view.observed.copies, [])
})

test('closing waits for an active nested recording to finish after cancellation', async () => {
  let release, aborted = false
  const finalized = new Promise(resolve => { release = resolve })
  const view = await controller({ session: async ({ signal }) => {
    signal.addEventListener('abort', () => { aborted = true }, { once: true })
    await finalized
  } })
  view.key('return'); view.key('r')
  await flush()
  assert.equal(view.observed.sessions, 1)
  let returned = false
  view.done.then(() => { returned = true })
  view.signal.abort()
  await flush()
  assert.equal(aborted, true)
  assert.equal(returned, false)
  release(); await view.done
  assert.deepEqual(pitches(view), [60])
  assert.equal(view.process.stdin.isRaw, false)
})

test('native playback owns pause, seek, resume, output identity and terminal teardown', async () => {
  const requests = [], calls = []
  let finishPlayback
  const completion = new Promise(resolve => { finishPlayback = resolve })
  const view = await controller({ output: 'loopback-UID', playback(value) {
    requests.push(value)
    return { ready: Promise.resolve(), completion,
      pause() { calls.push(['pause']) }, resume() { calls.push(['resume']) },
      seek(seconds) { calls.push(['seek', seconds]) }, status() {},
      stop() { calls.push(['stop']) }, terminate() { calls.push(['terminate']); finishPlayback() } }
  } })
  view.key('return'); view.key('space'); await flush()
  const [job] = view.observed.workers[0].requests
  view.observed.workers[0].emit('message', { id: job.id, ok: true, result: { path: '/synthetic/phrase.wav', clippedSamples: 0 } })
  await flush()
  assert.equal(requests[0].output, 'loopback-UID')
  requests[0].onEvent({ kind: 'playing', currentTime: 0, duration: 9.59999 })
  view.key('space'); await flush()
  requests[0].onEvent({ kind: 'paused', currentTime: 0.2, duration: 9.59999 })
  view.command('seek 2'); view.command('seek 16'); view.key('space'); await flush()
  assert.deepEqual(calls, [['pause'], ['seek', 1.2], ['seek', 9.59999], ['resume']])
  view.key('q'); await view.done
  assert.deepEqual(calls.slice(-2), [['stop'], ['terminate']])
  assert.equal(view.process.stdin.isRaw, false)
  assert.deepEqual(pitches(view), [60])
})

test('MIDI and audio route decisions fence obsolete jobs and drain the previous key owner', async t => {
  const requests = [], owners = []
  const view = await controller({ midiOutput: '-120', playback(value) {
    requests.push(value)
    let finish
    const completion = new Promise(resolve => { finish = resolve })
    const owner = { stopRequested: false, finish }
    owners.push(owner)
    return { ready: Promise.resolve(), completion,
      stop() { owner.stopRequested = true }, terminate() { finish() }, status() {} }
  } })
  t.after(async () => { view.signal.abort(); for (const owner of owners) owner.finish(); await view.done })
  const worker = view.observed.workers[0]
  const deliver = job => worker.emit('message', { id: job.id, ok: true, result: { path: job.path, clippedSamples: 0 } })
  view.key('return'); view.key('space'); await flush()
  const old = worker.requests[0]
  assert.equal(old.options.format, 'midi')
  view.command('midi-output -121'); view.key('space'); await flush()
  deliver(old); await flush()
  assert.equal(requests.length, 0)
  deliver(worker.requests[1]); await flush()
  assert.equal(requests[0].midiOutput, '-121')
  assert.equal(requests[0].output, undefined)
  view.command('output audio-UID'); view.key('space'); await flush()
  deliver(worker.requests[2]); await flush()
  assert.equal(owners[0].stopRequested, true)
  assert.equal(requests.length, 1)
  owners[0].finish(); await flush()
  assert.equal(requests[1].output, 'audio-UID')
  assert.equal(requests[1].midiOutput, undefined)
  assert.equal(worker.requests[2].options.format, 'wav')
  view.command('midi-output -122'); view.command('audio'); view.key('space'); await flush()
  deliver(worker.requests[3]); owners[1].finish(); await flush()
  assert.equal(requests[2].output, 'audio-UID')
  assert.equal(requests[2].midiOutput, undefined)
  view.key('q'); await view.done
  assert.equal(view.process.stdin.isRaw, false)
})


test('phrase-to-arrangement handoff preserves the editable parent, output intent and keyboard ownership',async()=>{
 let release;const closed=new Promise(resolve=>{release=resolve})
 const view=await controller({midiOutput:'-123',arrangement:()=>closed})
 view.command('chord Cmaj7 0 4 drop2');view.command('arrange');await flush()
 const worker=view.observed.workers[0],job=worker.requests[0]
 assert.equal(job.options.format,'arrangement')
 worker.emit('message',{id:job.id,ok:true,result:arrangementFromPhrase(job.project)});await flush()
 const handoff=view.observed.arrangements[0]
 assert.deepEqual(handoff.initialDocument.assets[0].phrase,job.project)
 assert.equal(handoff.initialRoute.kind,'midi');assert.equal(handoff.initialRoute.midiOutput,'-123')
 assert.equal(handoff.embedded,true);assert.equal(view.process.stdin.listenerCount('keypress'),0)
 release();await flush();assert.equal(view.process.stdin.listenerCount('keypress'),1)
 view.command('undo');view.key('q');await view.done
 assert.equal(view.observed.saved.at(-1).tracks[0].notes.length,0)
 assert.equal(handoff.initialDocument.assets[0].phrase.tracks[0].notes.length,4)
 assert.equal(view.process.stdin.isRaw,false)
})

test('closing pending arrangement preparation cancels it and rejects a late handoff',async()=>{
 const view=await controller();view.key('return');view.command('arrange');await flush()
 const worker=view.observed.workers[0],job=worker.requests[0]
 view.key('q');await view.done
 assert.equal(Atomics.load(new Int32Array(job.cancel),0),1)
 worker.emit('message',{id:job.id,ok:true,result:arrangementFromPhrase(job.project)});await flush()
 assert.equal(view.observed.arrangements.length,0);assert.equal(view.process.stdin.isRaw,false)
})

test('source-to-arrangement handoff retains the chosen independent pattern and MIDI destinations',async t=>{
 const chunk=p=>{const b=Buffer.from([0,0x90,p,100,0x83,0x60,0x80,p,77,0,0xff,0x2f,0]);const h=Buffer.alloc(8);h.write('MTrk');h.writeUInt32BE(b.length,4);return Buffer.concat([h,b])}
 const source=importMidiSource(Buffer.concat([Buffer.from('4d546864000000060002000201e0','hex'),chunk(60),chunk(62)]))
 let release;const pending=new Promise(resolve=>{release=resolve})
 const view=await controller({initialDocument:source,midiOutput:'-123',arrangement:()=>pending})
 t.after(async()=>{release();view.signal.abort();await view.done})
 view.command('pattern 2');view.command('midi-port 0 -124');view.command('arrange');await flush()
 const worker=view.observed.workers[0],job=worker.requests[0]
 assert.equal(job.options.format,'arrangement');assert.equal(job.options.pattern,1)
 assert.deepEqual(job.project,source)
 worker.emit('message',{id:job.id,ok:true,result:arrangementFromMidiSource(job.project,job.options)});await flush()
 const handoff=view.observed.arrangements[0]
 assert.deepEqual(handoff.initialDocument.assets[0].source,source)
 assert.equal(handoff.initialDocument.clips[0].pattern,1)
 assert.equal(handoff.initialRoute.kind,'midi');assert.equal(handoff.initialRoute.midiOutput,undefined)
 assert.deepEqual(handoff.initialRoute.portBindings,[{asset:handoff.initialDocument.assets[0].id,port:0,destination:'-124'}])
 assert.equal(view.process.stdin.listenerCount('keypress'),0)
 release();await flush();assert.equal(view.process.stdin.listenerCount('keypress'),1)
 view.key('q');await view.done
 assert.deepEqual(view.observed.saved.at(-1),source);assert.equal(view.process.stdin.isRaw,false)
})

test('parent shutdown aborts an active arrangement and waits for its child lifetime',async()=>{
 let release;const pending=new Promise(resolve=>{release=resolve})
 const view=await controller({arrangement:()=>pending});view.key('return');view.command('arrange');await flush()
 const worker=view.observed.workers[0],job=worker.requests[0]
 worker.emit('message',{id:job.id,ok:true,result:arrangementFromPhrase(job.project)});await flush()
 let returned=false;view.done.then(()=>{returned=true});view.signal.abort();await flush()
 assert.equal(view.observed.arrangements[0].signal.aborted,true);assert.equal(returned,false)
 release();await view.done;assert.equal(view.process.stdin.isRaw,false)
})

test('phrase selection renders the chosen VST, pins audio output and publishes player acknowledgements', async () => {
  const selection = { plugin_path: '/synth.vst3', plugin_name: 'Bass', preset_path: '/bass.vstpreset', name: 'Bass' }
  const requests = []; let completeNative, finishPlayback
  const nativeCompletion = new Promise(resolve => { completeNative = resolve })
  const completion = new Promise(resolve => { finishPlayback = resolve })
  const view = await controller({ autoSoundfont: false, output: 'speaker-UID',
    native({ preparation }) { return { promise: preparation.promise.then(() => nativeCompletion), cancel() {} } },
    playback(request) {
      requests.push(request)
      return { ready: Promise.resolve(), completion, status() {}, stop() {}, terminate() { finishPlayback() } }
    } })
  view.key('return'); view.key('l'); view.key('space'); await flush()
  assert.equal(view.observed.workers[0].requests.length, 0)
  const picker = view.observed.pickers[0]
  picker.close(); picker.selected(selection); await flush()
  const worker = view.observed.workers[0], job = worker.requests[0]
  assert.equal(job.options.format, 'vst-midi')
  assert.equal(job.options.loop, true)
  assert.deepEqual(view.observed.native[0].selection, selection)
  assert.equal(view.observed.native[0].loop, true)
  worker.emit('message', { id: job.id, ok: true, result: { path: job.path, duration: 1 } })
  const render = { output_path: '/retained/audio.wav', midi_path: '/retained/phrase.mid' }
  completeNative({ path: render.output_path, duration: 1, phraseDuration: 1, vst: render, selection })
  await flush()
  assert.equal(requests[0].path, render.output_path)
  assert.equal(requests[0].output, 'speaker-UID')
  assert.equal(requests[0].midiOutput, undefined)
  assert.equal(requests[0].loop, true)
  requests[0].onEvent({ kind: 'playing', currentTime: 0, duration: 1 }); await flush()
  requests[0].onEvent({ kind: 'playing', currentTime: 0.2, duration: 1 }); await flush()
  assert.equal(view.observed.snapshots.filter(row => row.state === 'player_playing').length, 1)
  assert.deepEqual(view.observed.snapshots.find(row => row.state === 'player_playing').selection, selection)
  view.key('q'); await view.done
  assert.equal(view.process.stdin.isRaw, false)
})

test('close cancels an owned VST and waits for its late completion without opening a player', async () => {
  let complete, stops = 0
  const nativeCompletion = new Promise(resolve => { complete = resolve })
  const view = await controller({ autoSoundfont: false,
    native({ preparation }) { return { promise: preparation.promise.then(() => nativeCompletion), cancel() { stops++ } } } })
  view.key('return'); view.key('space'); await flush()
  const picker = view.observed.pickers[0]
  picker.close(); picker.selected({ plugin_path: '/chosen.vst3', plugin_name: null, preset_path: null, name: 'Chosen' })
  await flush()
  const worker = view.observed.workers[0], job = worker.requests[0]
  worker.emit('message', { id: job.id, ok: true, result: { path: job.path } }); await flush()
  let returned = false
  view.done.then(() => { returned = true })
  view.key('q'); await flush()
  assert.ok(stops > 0)
  assert.equal(returned, false)
  complete({ path: '/late.wav', vst: {} }); await view.done
  assert.equal(view.observed.players, 0)
  assert.equal(view.process.stdin.isRaw, false)
})

test('WAV export prepares the selected SMF2 pattern with the chosen VST', async t => {
  const chunk = (name, data) => {
    const header = Buffer.alloc(8); header.write(name); header.writeUInt32BE(data.length, 4)
    return Buffer.concat([header, data])
  }
  const track = pitch => chunk('MTrk', Buffer.from([0, 0x90, pitch, 100, 0x83, 0x60, 0x80, pitch, 0, 0, 255, 47, 0]))
  const source = importMidiSource(Buffer.concat([
    chunk('MThd', Buffer.from([0, 2, 0, 2, 1, 224])), track(60), track(67),
  ]))
  const selection = { plugin_path: '/chosen.vst3', plugin_name: null, preset_path: null, name: 'Chosen' }
  const view = await controller({ initialDocument: source, autoSoundfont: false,
    native({ preparation }) {
      return { promise: preparation.promise.then(() => ({ path: '/retained/pattern-2.wav', clippedSamples: 0 })), cancel() {} }
    } })
  t.after(async () => { view.signal.abort(); await view.done })
  view.command('pattern 2'); view.key('i'); await flush()
  const picker = view.observed.pickers[0]
  picker.close(); picker.selected(selection); await flush()
  view.command('stop'); view.command('wave /synthetic/pattern-2.wav'); await flush()
  const worker = view.observed.workers[0], job = worker.requests.at(-1)
  assert.equal(worker.requests.length, 2)
  assert.equal(job.options.format, 'vst-midi')
  assert.equal(job.options.pattern, 1)
  assert.deepEqual(job.project, { ...source, sound: frozenSound(selection) })
  assert.deepEqual(view.observed.native.at(-1).selection, selection)
  worker.emit('message', { id: job.id, ok: true, result: { path: job.path, duration: 0.5 } })
  await flush()
  assert.deepEqual(view.observed.copies, [['/retained/pattern-2.wav', '/synthetic/pattern-2.wav']])
  assert.equal(view.observed.players, 0)
})

test('expression keyboard decisions edit the selected event, preserve notes, undo removal and save before closing',async()=>{
 const bytes=Buffer.from('4d546864000000060000000101e04d54726b0000001d00b0014d00e0004000903c608360803c2d8360ff2f00','hex')
 bytes.writeUInt32BE(bytes.length-22,18);const source=importMidiSource(bytes)
 const view=await controller({initialDocument:source})
 try {
  view.command('events');await flush()
  view.key(undefined,'+');await flush()
  view.key('return');await flush()
  view.key('backspace');view.key('backspace');view.key(undefined,'81');view.key('return');await flush()
  view.key('down');await flush();view.key('x');view.key('u');view.key('s');await flush()
  const saved=view.observed.saved.at(-1),events=midiSourcePattern(saved).events
  assert.ok(events.some(e=>e.kind==='channel'&&e.bytes[0]===0xb0&&e.bytes[2]===81))
  assert.ok(events.some(e=>e.kind==='channel'&&e.bytes[0]===0xe0))
  assert.deepEqual(midiSourcePattern(saved).notes,midiSourcePattern(source).notes)
  assert.equal(saved.original,source.original)
 }finally{view.key('q');await view.done}
 assert.equal(view.process.stdin.isRaw,false)
})

test('an admitted event-before command drains into the saved source on close without changing note time',async()=>{
 const bytes=Buffer.from('4d546864000000060000000101e04d54726b0000000000903c608360803c2d00ff2f00','hex')
 bytes.writeUInt32BE(bytes.length-22,18);const source=importMidiSource(bytes),view=await controller({initialDocument:source})
 view.command('cc 1 0 0');view.command('event-before first-note');view.key('q');await view.done
 const saved=view.observed.saved.at(-1),performance=midiSourcePattern(saved)
 assert.deepEqual(performance.events.slice(0,2).map(event=>event.bytes),[[0xb0,1,0],[0x90,60,96]])
 assert.deepEqual(performance.notes,midiSourcePattern(source).notes)
 assert.equal(saved.original,source.original);assert.equal(view.process.stdin.isRaw,false)
})

test('tempo keyboard decisions and an admitted tempo edit drain into close without changing source note ticks',async()=>{
 const bytes=Buffer.from('4d546864000000060000000101e04d54726b0000000000ff510307a12000903c608360803c2d00ff2f00','hex')
 bytes.writeUInt32BE(bytes.length-22,18);const source=importMidiSource(bytes),view=await controller({initialDocument:source})
 try{
  view.command('tempos');await flush();view.key(undefined,'+');view.key('s');await flush()
  assert.ok(midiSourcePattern(view.observed.saved.at(-1)).seconds<.5)
  view.key('return');await flush();for(const char of String(sourceTempos(editor.newEditor(view.observed.saved.at(-1)))[0].value))view.key('backspace');view.key(undefined,'60');view.key('return');await flush()
  view.command('tempo 120 0.5');view.key('q');await view.done
  const saved=view.observed.saved.at(-1),after=midiSourcePattern(saved)
  assert.equal(after.seconds,.75);assert.equal(saved.original,source.original)
  assert.deepEqual(after.notes.map(n=>[n.id,n.off,n.start,n.duration]),midiSourcePattern(source).notes.map(n=>[n.id,n.off,n.start,n.duration]))
 }finally{view.key('q');await view.done}
 assert.equal(view.process.stdin.isRaw,false)
})

test('source loop owns current range, routes region playback, seeks locally and retires obsolete preparations on toggle', async () => {
 const {midiSourceFromEvents}=await import('../midi-source.mjs')
 const project=midiSourceFromEvents([{tick:0,kind:'channel',bytes:[0x90,60,96]},
  {tick:1920,kind:'channel',bytes:[0x80,60,47]},{tick:1920,kind:'meta',type:0x2f,data:[]}],{ppq:960})
 let opened,finish;const commands=[]
 const view=await controller({initialDocument:project,midiOutput:'42',playback(value){
  opened=value
  const handle={pause(){commands.push('pause')},resume(){commands.push('resume')},seek(seconds){commands.push(seconds)},stop(){commands.push('stop');finish()},
   ready:Promise.resolve(),completion:new Promise(resolve=>{finish=resolve})}
  return handle
 }})
 view.command('loop .5 1.5');view.command('play');await flush()
 const worker=view.observed.workers[0],old=worker.requests.at(-1)
 assert.deepEqual(old.options.sourceLoop,{start:480,end:1440});assert.equal(old.options.loop,true)
 view.key('l');await flush();assert.equal(Atomics.load(new Int32Array(old.cancel),0),1)
 worker.emit('message',{id:old.id,ok:true,result:{path:'/obsolete',format:'midi-arrangement'}});await flush()
 assert.equal(view.observed.players,0)
 view.command('loop .5 1.5');view.command('play');await flush()
 const next=worker.requests.at(-1),sourceWindow={start:480,end:1440,startSeconds:.25,endSeconds:.75}
 worker.emit('message',{id:next.id,ok:true,result:{path:'/owned/region',duration:.5,format:'midi-arrangement',midiOutput:'42',midiBindings:[{port:0,destination:'42'}],sourceWindow}});await flush()
 assert.equal(opened.format,'midi-arrangement');assert.equal(opened.loop,true)
 opened.onEvent({kind:'playing',currentTime:0,duration:.5});await flush()
 view.command('seek 1');view.command('seek 0');view.command('seek 1.5');await flush()
 assert.deepEqual(commands,[.25,.5])
 view.key('space');await flush();assert.equal(commands.at(-1),'pause')
 opened.onEvent({kind:'paused',currentTime:.1,duration:.5});view.key('space');await flush();assert.equal(commands.at(-1),'resume')
 view.command('transpose 2');await flush();assert.equal(commands.at(-1),'stop')
 view.key('q');await view.done
 assert.deepEqual(midiSourcePattern(view.observed.saved.at(-1)).notes.map(note=>note.pitch),[62])
})

test('phrase loop command enables its range, retires old preparation and retains the range after toggling off',async()=>{
 let opened,finish;const calls=[]
 const view=await controller({midiOutput:'42',playback(value){
  opened=value
  return{ready:Promise.resolve(),completion:new Promise(resolve=>{finish=resolve}),stop(){calls.push('stop');finish()}}
 }})
 try{
  view.command('loop 1 3');view.command('play');await flush()
  const worker=view.observed.workers[0],old=worker.requests.at(-1)
  assert.equal(old.options.loop,true);assert.deepEqual(old.project.loop,{start:PPQ,end:3*PPQ})
  view.command('loop 2 4');view.command('loop 8 1');await flush()
  assert.equal(Atomics.load(new Int32Array(old.cancel),0),1)
  worker.emit('message',{id:old.id,ok:true,result:{path:'/obsolete',format:'midi'}});await flush()
  assert.equal(view.observed.players,0)
  view.command('play');await flush();const next=worker.requests.at(-1)
  assert.equal(next.options.loop,true);assert.deepEqual(next.project.loop,{start:2*PPQ,end:4*PPQ})
  worker.emit('message',{id:next.id,ok:true,result:{path:'/owned',duration:1.2,format:'midi',midiOutput:'42'}});await flush()
  assert.equal(opened.loop,true);opened.onEvent({kind:'playing',currentTime:0,duration:1.2})
  view.key('l');await flush();assert.deepEqual(calls,['stop'])
  view.command('play');await flush();assert.equal(worker.requests.at(-1).options.loop,false)
 }finally{view.key('q');await view.done}
 assert.deepEqual(view.observed.saved.at(-1).loop,{start:2*PPQ,end:4*PPQ})
})
