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
import { harmonyAt, PPQ } from '../sequencer-project.mjs'

// Exercise actual controller decisions with owned IO substitutes. No terminal
// output, layout, audio hardware or player behavior is asserted.
async function controller(options = {}) {
  const observed = { saved: [], workers: [], writes: [], copies: [], sessions: 0, players: 0, arrangements: [] }
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
  const slot = `sequencer-${randomUUID()}`
  globalThis[slot] = {
    process, mkdtemp: async () => '/synthetic-temp', rm: async () => {},
    writeFile: async path => { observed.writes.push(path) },
    copyFile: async (from, to) => { observed.copies.push([from, to]) },
    arrangementRoute, selectArrangementRoute, dirname, constants, join, resolve, tmpdir: () => '/synthetic', randomUUID, emitKeypressEvents() {},
    openPlayback(value) { observed.players++; if (options.playback) return options.playback(value); throw new Error('Unexpected playback') }, Worker,
    Note: { fromMidi: String }, ...editor, harmonyAt, PPQ,
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
  const done = viewSequencer({ root: '/synthetic', output: options.output, midiOutput: options.midiOutput, signal: signal.signal }).finally(() => { delete globalThis[slot] })
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
  view.key('return'); view.command('wave /synthetic/export.wav')
  await flush()
  const [job] = view.observed.workers[0].requests
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

test('MIDI and audio route decisions fence obsolete jobs and drain the previous key owner', async () => {
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
