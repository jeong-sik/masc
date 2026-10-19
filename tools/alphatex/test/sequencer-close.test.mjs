import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { EventEmitter } from 'node:events'
import { join, resolve, dirname } from 'node:path'
import { randomUUID } from 'node:crypto'
import { constants } from 'node:fs'
import { arrangementRoute, selectArrangementRoute } from '../arrangement-playback.mjs'
import { arrangementFromPhrase } from '../phrase-arrangement.mjs'
import * as editor from '../sequencer-editor.mjs'
import { sourceExpressions, selectedExpression } from '../midi-source-editor.mjs'
import { importMidiSource, midiSourcePattern } from '../midi-source.mjs'
import { harmonyAt, PPQ } from '../sequencer-project.mjs'

// Exercise actual controller decisions with owned IO substitutes. No terminal
// output, layout, audio hardware or player behavior is asserted.
async function controller(options = {}) {
  const observed = { saved: [], workers: [], writes: [], copies: [], sessions: 0, players: 0, arrangements: [], pickers: [], native: [], snapshots: [] }
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
  const slot = `sequencer-${randomUUID()}`
  globalThis[slot] = {
    process, InstrumentPicker, defaultStateDirectory: () => '/synthetic-vst',
    snapshotWriter: () => async value => { observed.snapshots.push(value) },
    renderVstPhrase(value) { observed.native.push(value); return options.native(value) },
    mkdtemp: async () => '/synthetic-temp', rm: async () => {},
    writeFile: async path => { observed.writes.push(path) },
    copyFile: async (from, to) => { observed.copies.push([from, to]) },
    arrangementRoute, selectArrangementRoute, dirname, constants, join, resolve, tmpdir: () => '/synthetic', randomUUID, emitKeypressEvents() {},
    openPlayback(value) { observed.players++; if (options.playback) return options.playback(value); throw new Error('Unexpected playback') }, Worker,
    Note: { fromMidi: String }, ...editor, harmonyAt, PPQ, sourceExpressions, selectedExpression,
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
  assert.deepEqual(job.project, source)
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
