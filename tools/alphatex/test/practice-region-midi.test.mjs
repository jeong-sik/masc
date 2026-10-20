import test, { before, after } from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { readFile, readdir, mkdir, writeFile, chmod, mkdtemp, rm } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { practiceSourceFixture } from './helpers/practice-source-fixture.mjs'
import { nominalMidiFrame } from '../render-midi-clock.mjs'
import { phraseBacking } from '../phrase-backing.mjs'
import { newArrangement } from '../arrangement.mjs'
import { importArrangementPractice, importPracticeMidi, saveArrangement, loadArrangement } from '../arrangement-files.mjs'
import { arrangementEditor, arrangementCommand, arrangementImported, arrangementAction } from '../arrangement-editor.mjs'
import { midiSourcePattern } from '../midi-source.mjs'
import { practiceRange } from '../practice-source.mjs'

const execute = promisify(execFile)
let build, nativeExecutable
before(async () => {
  build = await mkdtemp(join(tmpdir(), 'masc-practice-region-native-'))
  nativeExecutable = join(build, 'music-arrangement')
  const native = ['WaveArrangement', 'WaveLoopClock', 'SourceAudioClock', 'CaptureAudioClock', 'PulseAudioClock',
    'PulseLoopClock', 'MidiTransport', 'UmpTransport', 'UmpOutput', 'UmpRegions', 'HybridMidiTransport', 'UmpLoopTransport', 'UmpState']
  await execute('xcrun', ['swiftc', '-parse-as-library', '-D', 'MIDI_LIBRARY', '-O',
    ...native.map(name => fileURLToPath(new URL(`../native/${name}.swift`, import.meta.url))),
    '-o', nativeExecutable, '-framework', 'AVFoundation', '-framework', 'CoreAudio', '-framework', 'CoreMIDI'])
})
after(async () => { if (build) await rm(build, { recursive: true, force: true }) })

async function fixture(run, messages = [
  [-1n, [0xb5, 64, 127]],
  ...[60, 64, 67, 71].map(pitch => [120000n, [0x95, pitch, 100]]),
  [240000n, [0xe5, 1, 65]], [240001n, [0xd5, 44]],
  ...[60, 64, 67, 71].map(pitch => [360000n, [0x85, pitch, 47]]),
]) {
  return practiceSourceFixture(async data => {
    const { root, arm, context, rows, receipt, publish, input } = data
    context.project.tempo = 137; context.project.meter = [7, 8]
    context.backing = phraseBacking(context.project, context.track, true)
    arm.renderClock.anchor.hostTime = '10000000000000000000'
    rows.splice(0, rows.length, ...messages.map(([delta, bytes], index) => {
      const words = bytes.length === 2 && bytes[0] > 255 ? bytes : [((0x23 << 24) | (bytes[0] << 16) | (bytes[1] << 8) | (bytes[2] ?? 0)) >>> 0]
      const packet = { kind: 'midi', protocol: 2, source: '10', ordinal: String(index),
        hostTime: String(BigInt(arm.renderClock.anchor.hostTime) + delta), timestampOrigin: 'packet', words }
      return { packet, nominalFrame: nominalMidiFrame(packet.hostTime, arm.input.clock, arm.renderClock) }
    }))
    receipt.packets = String(rows.length)
    receipt.inputFinal.admittedPackets = receipt.inputFinal.acknowledgedPackets = receipt.packets
    const lastDelta = messages.reduce((last, [delta]) => delta > last ? delta : last, 0n)
    const after = (lastDelta * 125n * 48000n + 3_000_000_000n - 1n) / 3_000_000_000n + 1n
    if (after > 4800n) {
      Object.assign(receipt.monitorFinal.pcm.final, { renderedFrames: String(after), admittedFrames: String(after + 1024n) })
      receipt.monitorFinal.pcm.sentFrames = String(after + 1024n)
    }
    await publish()
    const path = join(root, 'project/song.json'), imported = await importArrangementPractice(newArrangement(), input, { projectPath: path })
    const directory = join(root, 'scratch'); await mkdir(directory)
    const worker = new Worker(new URL('../arrangement-worker.mjs', import.meta.url)); let id = 0
    const request = async job => {
      const pending = once(worker, 'message'); worker.postMessage({ ...job, id: ++id })
      const [reply] = await pending; if (!reply.ok) throw new Error(reply.error); return reply.result
    }
    try { await run({ ...data, path, imported, directory, request }) } finally { await worker.terminate() }
  })
}

const word = (status, number, value = 0) => ((0x23 << 24) | status << 16 | number << 8 | value) >>> 0
const wire = source => midiSourcePattern(source).events.filter(event => event.kind === 'channel')
const derive = (data, cut, project = data.imported.project) => data.request({ kind: 'practice-midi-region',
  project, asset: data.imported.asset, cut, sourceRoot: dirname(data.path), directory: data.directory, nativeExecutable })

test('selected cut and cursor survive another asset selection and capture attachment; original regions and private files survive save', () => fixture(async data => {
  const { imported, files, root, path, directory } = data
  const parts = await Promise.all(Object.values(files).map(file => readFile(file)))
  let editor = arrangementEditor(imported.project)
  editor = arrangementCommand(editor, `practice-region ${imported.asset} 4 240001 960000 2 3`).editor
  editor = arrangementCommand(editor, 'cursor 7').editor
  const raw = structuredClone(editor.project.clips[0]), original = structuredClone(editor.project)
  // An admitted region command addresses the region, even if the library points elsewhere.
  editor.asset = 'different-library-selection'
  const effect = arrangementCommand(editor, 'practice-midi-region').effect
  assert.deepEqual(effect, { kind: 'practice-midi-region', asset: imported.asset, tick: 6720,
    cut: { offset: '240001', extent: '960000', sourceDivisor: '2' } })
  const attached = structuredClone(editor.project)
  attached.name = 'capture attached while the request settles'
  const result = await data.request({ ...effect, project: attached, sourceRoot: dirname(path), directory, nativeExecutable })
  const adopted = arrangementImported(editor, result), source = adopted.project.assets.at(-1).source
  const pattern = midiSourcePattern(source)
  assert.equal(adopted.project.name, attached.name)
  assert.equal(pattern.notes.length, 4); assert.ok(pattern.notes.every(note => note.start === 0))
  assert.equal(pattern.ticks, 44) // 480000 host ticks at 125/3 ns, 137 BPM SMF tempo.
  assert.deepEqual(adopted.project.clips[0], raw); assert.deepEqual(editor.project, original)
  const undo = arrangementAction(adopted, { kind: 'undo' })
  assert.deepEqual(undo.project, original)
  const saved = join(root, 'portable/song.json')
  await saveArrangement(saved, adopted.project, null, { sourceRoot: dirname(path) })
  assert.deepEqual((await loadArrangement(saved)).project, adopted.project)
  assert.deepEqual(await Promise.all(Object.values(files).map(file => readFile(file))), parts)
  assert.deepEqual(await readdir(directory), [])
  assert.throws(() => arrangementCommand(arrangementEditor(newArrangement()), 'practice-midi-region'), /original practice region/)
}))

test('fractional entry excludes expired attributes and outside suffix; boundaries retain stable original note pairs', () => fixture(async data => {
  const result = await derive(data, { offset: '4000001', extent: '4000000', sourceDivisor: '2' })
  const source = result.project.assets.at(-1).source, pattern = midiSourcePattern(source)
  assert.deepEqual(pattern.diagnostics, [])
  assert.deepEqual(pattern.notes.map(({ pitch, start, duration }) => ({ pitch, start, duration })).sort((a, b) => a.pitch - b.pitch), [
    { pitch: 62, start: 0, duration: 91 }, { pitch: 64, start: 0, duration: 0 },
  ])
  assert.deepEqual(wire(source).filter(event => [0x90, 0x80].includes(event.bytes[0] & 0xf0)).map(event => event.bytes[1]), [62, 64, 64, 62])
  const before = structuredClone(data.imported.project)
  await assert.rejects(derive(data, { offset: '0', extent: '1' }), /attributes/)
  assert.deepEqual(data.imported.project, before)
}, [[0n, [0x43953c03, 0x90012345]], [1n, [0x43853c00, 0]],
  [2000000n, [0x43953e00, 0xc8000000]], [2000001n, [0x43954000, 0xb4000000]], [2000001n, [0x43854000, 0x50000000]],
  [3000000n, [0x43853e00, 0x5e000000]], [4000001n, [0x43954303, 0x90012345]]]))

test('sustain and sostenuto restore released sounding voices and preserve pedal order without extending key durations', () => fixture(async data => {
  const result = await derive(data, { offset: '5', extent: '1000000' })
  const source = result.project.assets.at(-1).source
  assert.deepEqual(wire(source).slice(2, 7).map(event => [event.tick, event.bytes]), [
    [0, [0x90, 60, 100]], [0, [0xb0, 66, 127]], [0, [0x80, 60, 42]],
    [0, [0xb0, 64, 127]], [0, [0x90, 62, 90]],
  ])
  assert.deepEqual(midiSourcePattern(source).notes.map(({ pitch, duration }) => [pitch, duration]), [[60, 0], [62, 0]])
  assert.ok(wire(source).some(event => event.bytes[0] === 0xb0 && event.bytes[1] === 66 && event.bytes[2] === 0 && event.tick > 0))
}, [[0n, [0x95, 60, 100]], [1n, [0xb5, 66, 127]], [2n, [0x85, 60, 42]],
  [3n, [0xb5, 64, 127]], [4n, [0x95, 62, 90]], [5n, [0x85, 62, 43]],
  [500000n, [0xb5, 66, 0]], [700000n, [0xb5, 64, 0]]]))

test('exclusive end clips held keys and MIDI2 values project only within the selected window', () => fixture(async data => {
  const result = await derive(data, { offset: '0', extent: '1000000' })
  const source = result.project.assets.at(-1).source, pattern = midiSourcePattern(source)
  assert.deepEqual(pattern.notes.map(({ pitch, start, duration, velocity }) => ({ pitch, start, duration, velocity })), [
    { pitch: 60, start: 0, duration: 91, velocity: 72 },
  ])
  assert.deepEqual(pattern.diagnostics, []); assert.equal(pattern.ticks, 91)
}, [[0n, [0x43953c00, 0x90000000]], [1000000n, [0x43954003, 0x90012345]], [1100000n, [0x43853c00, 0x10000000]]]))

test('native failure and cancellation leave no adopted asset or private snapshot', () => fixture(async data => {
  const before = structuredClone(data.imported.project), cut = { offset: '1', extent: '1000000' }
  await assert.rejects(derive(data, cut), /compound/)
  const abort = new AbortController(); abort.abort()
  await assert.rejects(importPracticeMidi(data.imported.project, data.imported.asset, {
    sourceRoot: dirname(data.path), directory: data.directory, cut, nativeExecutable, signal: abort.signal }), { name: 'AbortError' })
  await assert.rejects(data.request({ kind: 'practice-midi-region', project: data.imported.project,
    asset: data.imported.asset, cut, sourceRoot: dirname(data.path), directory: data.directory,
    nativeExecutable: join(data.root, 'missing-native') }), /ENOENT/)
  assert.deepEqual(data.imported.project, before); assert.deepEqual(await readdir(data.directory), [])
}, [[0n, [0xb5, 101, 0]], [1n, [0x95, 60, 100]]]))

test('offline native extraction retains sub-tick offsets even when absolute cross products overflow', async () => {
  const base = 1000000000000000000n, divisor = 100000000000000000000n
  const plan = { schemaVersion: 1, offset: String(base * divisor + 1n), extent: String(3n * divisor), sourceDivisor: String(divisor),
    source: { id: 'take', extent: String(base + 5n), timeline: { schemaVersion: 4, duration: 1000000001,
      clock: { origin: '0', numer: 1, denom: 1 }, bindings: [{ source: '10', destination: '10' }],
      packets: [[base, word(0x95, 60, 100)], [base + 1n, word(0x85, 60, 40)],
        [base + 3n, word(0x95, 62, 90)], [base + 4n, word(0x85, 62, 0)]].map(([at, value]) => ({
          kind: 'midi', protocol: 2, hostTime: String(at), source: '10', timestampOrigin: 'packet', words: [value] })) } } }
  const path = join(build, 'large-region.json'); await writeFile(path, JSON.stringify(plan), { mode: 0o600 })
  const { stdout } = await execute(nativeExecutable, ['extract-practice-region', '--file', path])
  const result = JSON.parse(stdout)
  assert.deepEqual(result.events.map(row => [row.offset, row.words]), [
    ['0', [word(0x95, 60, 100)]], [String(divisor - 1n), [word(0x85, 60, 40)]],
    [String(3n * divisor - 1n), [word(0x95, 62, 90)]],
  ])
})
