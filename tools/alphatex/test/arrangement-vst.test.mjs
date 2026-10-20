import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { mkdtemp, mkdir, writeFile, readFile, rm, access, readdir } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { join, dirname } from 'node:path'
import { tmpdir } from 'node:os'
import { newArrangement, editArrangement } from '../arrangement.mjs'
import { importArrangementWave, importArrangementCapture, saveArrangement, loadArrangement } from '../arrangement-files.mjs'
import { importMidiSource, midiSourcePattern } from '../midi-source.mjs'
import { sourceAudioClock, sourceAudioFrames } from '../source-audio-clock.mjs'
import { arrangementPlaybackRequest, arrangementRoute } from '../arrangement-playback.mjs'
import { startVstArrangement } from '../arrangement-vst.mjs'

const hash = bytes => createHash('sha256').update(bytes).digest('hex')
const state = Buffer.from('frozen instrument state')
const sound = { kind: 'vst', selection: { plugin_path: '/fixture.vst3', plugin_name: null, preset_path: null, name: 'Fixture' },
  preset: { data: state.toString('base64'), sha256: hash(state) }, instrument: { identifier: 'FixtureID', version: '1' } }
function wave(frames, rate = 44100, channels = 2) {
  const bytes = Buffer.alloc(44 + frames * channels * 2)
  bytes.write('RIFF'); bytes.writeUInt32LE(bytes.length - 8, 4); bytes.write('WAVEfmt ', 8)
  bytes.writeUInt32LE(16, 16); bytes.writeUInt16LE(1, 20); bytes.writeUInt16LE(channels, 22)
  bytes.writeUInt32LE(rate, 24); bytes.writeUInt32LE(rate * channels * 2, 28)
  bytes.writeUInt16LE(channels * 2, 32); bytes.writeUInt16LE(16, 34); bytes.write('data', 36); bytes.writeUInt32LE(bytes.length - 44, 40)
  for (let i = 44; i < bytes.length; i += 2) bytes.writeInt16LE(100, i)
  return bytes
}
const gate = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no }); return { promise, resolve, reject } }
async function fixture(action) {
  const root = await mkdtemp(join(tmpdir(), 'masc-vst-arrangement-test-')), worker = new Worker(new URL('../arrangement-worker.mjs', import.meta.url))
  let sequence = 0
  const jobs = new Map(), requests = [], calls = [], owners = []
  const fail = error => { for (const job of jobs.values()) job.reject(error); jobs.clear(); for (const owner of owners) owner.cancel() }
  worker.on('error', fail); worker.on('exit', () => fail(new Error('Worker closed')))
  worker.on('message', row => {
    const job = jobs.get(row.id); if (!job) return
    jobs.delete(row.id)
    if (row.ok) job.resolve(row.result)
    else job.reject(new Error(row.error))
  })
  const request = (value, issued) => new Promise((resolve, reject) => {
    const id = ++sequence; jobs.set(id, { resolve, reject }); issued?.(id); requests.push(value); worker.postMessage({ ...value, id })
  })
  const cancelRequest = id => worker.postMessage({ kind: 'cancel', request: id })
  const run = value => {
    calls.push(value)
    return { cancel() {}, promise: (async () => {
      assert.deepEqual(await readFile(value.preset_path), state)
      const midi = await readFile(value.midi_path), performance = midiSourcePattern(importMidiSource(midi))
      const frames = sourceAudioFrames(sourceAudioClock(performance, 0, performance.ticks), 44100).frameCount, bytes = wave(frames)
      await writeFile(value.output_path, bytes, { flag: 'wx' })
      return { output_path: value.output_path, midi_sha256: hash(midi), preset_sha256: hash(state), wav_sha256: hash(bytes),
        instrument: sound.instrument, sample_rate: 44100, frames }
    })() }
  }
  let project = newArrangement({ tempo: 120 })
  const file = join(root, 'backing.wav'); await writeFile(file, wave(48000, 48000, 1))
  project = (await importArrangementWave(project, file, { projectPath: join(root, 'song.json') })).project
  project = editArrangement(project, { kind: 'lane-add', sourceKind: 'wave', name: 'Backing' })
  project = editArrangement(project, { kind: 'region-add', name: 'Backing', asset: 'asset-1', lane: 'lane-1', position: 0, offset: 0, extent: 48000, repeat: 1 })
  const midi = Buffer.from('4d546864000000060000000101e04d54726b0000000d00903c648360803c4d00ff2f00', 'hex')
  project = editArrangement(project, { kind: 'asset-add', asset: { id: 'v', name: 'Frozen', kind: 'midi', source: importMidiSource(midi, { sound }) } })
  project = editArrangement(project, { kind: 'lane-add', sourceKind: 'midi', name: 'Instrument' })
  project = editArrangement(project, { kind: 'region-add', name: 'One', asset: 'v', lane: 'lane-2', position: 480, offset: 1, extent: 478, repeat: 3 })
  project = editArrangement(project, { kind: 'region-add', name: 'Two', asset: 'v', lane: 'lane-2', position: 4000, offset: 0, extent: 480, repeat: 1 })
  const start = (project, route = arrangementRoute({ output: 'AudioUID' }), selectedRun = run, selectedRequest = request) => {
    assert.equal(arrangementPlaybackRequest(project, route).kind, 'prepare-vst')
    const owner = startVstArrangement({ project, route, sourceRoot: root, directory: root, request: selectedRequest, cancelRequest, run: selectedRun })
    owners.push(owner); return owner
  }
  try { await action({ root, worker, project, start, run, calls, requests, request, midi }) }
  finally { await Promise.all(owners.map(owner => owner.dispose())); await worker.terminate(); await rm(root, { recursive: true, force: true }) }
}

test('worker export, parent rendering and assembly preserve frozen original sources, exact trims, one render and portable reopen', () => fixture(async ({ root, project, start, calls, midi }) => {
  const before = structuredClone(project), owner = start(project), prepared = await owner.promise
  const plan = JSON.parse(await readFile(prepared.path))
  assert.equal(prepared.format, 'wave-arrangement'); assert.equal(calls.length, 1)
  assert.equal(calls[0].tail_seconds, 0); assert.equal(calls[0].sample_rate, 44100)
  assert.equal(plan.assets.length, 2)
  const derived = plan.regions.filter(region => region.sourceClock)
  assert.equal(derived.length, 2); assert.equal(derived[0].repeat, 3)
  assert.deepEqual(derived[0].sourceClock, { start: '500000', end: '239500000', denominator: '480000000' })
  assert.equal(derived[0].offsetFrames, 46); assert.equal(derived[0].frameCount, 21959)
  assert.equal(derived[0].asset, derived[1].asset); assert.notEqual(derived[0].asset, 'v')
  assert.deepEqual(project, before); assert.deepEqual(Buffer.from(project.assets[1].source.original, 'base64'), midi)
  const path = join(root, 'portable', 'song.json')
  await saveArrangement(path, project, null, { sourceRoot: root })
  assert.deepEqual((await loadArrangement(path)).project, before)
  const owned = dirname(prepared.path); await access(owned); await owner.dispose()
  await assert.rejects(access(owned), { code: 'ENOENT' })
}))

test('VST plus residual MIDI use one mixed clock and practice is applied once; loop keeps absolute source placement', () => fixture(async ({ project, start, requests }) => {
  project = editArrangement(project, { kind: 'asset-add', asset: { ...project.assets[1], id: 'external', name: 'External' } })
  project = editArrangement(project, { kind: 'region-add', name: 'External', asset: 'external', lane: 'lane-2', position: 0, offset: 0, extent: 480, repeat: 4 })
  project = { ...project, practice: { countInBars: 1, metronome: true }, playbackLoop: { start: 240, end: 960 } }
  const route = { kind: 'mixed', output: 'AudioUID', portBindings: [{ asset: 'external', port: 0, destination: '-42' }] }
  const owner = start(project, route), result = await owner.promise, plan = JSON.parse(await readFile(result.path))
  assert.equal(plan.kind, 'mixed-arrangement'); assert.equal(plan.midi.sources.length, 1)
  assert.equal(plan.midi.regions.length, 1); assert.equal(plan.midi.regions[0].startSeconds, 0)
  assert.equal(plan.midi.regions[0].repeatCount, 4)
  assert.equal(plan.regions.filter(region => region.sourceClock).length, 1)
  assert.equal(plan.regions.filter(region => region.pulseClock).length, 2)
  assert.equal(plan.practice.countInSeconds, 2); assert.equal(result.originSeconds, .125)
  assert.equal(plan.regions.find(region => region.sourceClock).projectTick, 480)
  assert.deepEqual(result.bindings, [{ port: 0, destination: '-42' }])
  assert.deepEqual(requests.map(request => request.kind), ['prepare-vst-sources', 'prepare-vst-plan'])
}))

test('external override is complete and partial mappings fail before any plugin; failed worker preparation releases the root', () => fixture(async ({ root, project, start, calls }) => {
  const before = await readdir(root)
  project = editArrangement(project, { kind: 'asset-add', asset: { ...project.assets[1], id: 'external', name: 'External' } })
  project = editArrangement(project, { kind: 'region-add', name: 'External', asset: 'external', lane: 'lane-2', position: 0, offset: 0, extent: 480, repeat: 1 })
  const owner = start(project, { kind: 'mixed', output: 'AudioUID', portBindings: [{ asset: 'external', port: 1, destination: '-42' }] })
  await assert.rejects(owner.promise, /port|output/); assert.equal(calls.length, 0)
  assert.deepEqual(await readdir(root), before)
  assert.equal(arrangementPlaybackRequest(project, arrangementRoute({ output: 'Audio', midiOutput: '-42' })).kind, 'prepare-mixed')
}))

test('stop and worker exit during native render retain preset/source/root until the child closes, then discard late success', () => fixture(async ({ root, worker, project, start }) => {
  const before = await readdir(root), entered = gate(), closed = gate()
  let cancels = 0
  const owner = start(project, undefined, request => {
    entered.resolve(request)
    return { promise: closed.promise, cancel() { cancels++ } }
  })
  const request = await entered.promise, owned = dirname(request.output_path)
  await worker.terminate(); owner.cancel()
  const disposed = owner.dispose(); let settled = false; disposed.then(() => { settled = true })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(settled, false); assert.ok(cancels > 0)
  await access(request.preset_path); await access(request.midi_path); await access(owned)
  closed.resolve({ preset_sha256: sound.preset.sha256 })
  await assert.rejects(owner.promise, /cancel|abort/i); await disposed
  await assert.rejects(access(owned), { code: 'ENOENT' }); assert.deepEqual(await readdir(root), before)
}))

test('immediate cancellation and assembly failure without a final result both release owned roots', () => fixture(async ({ root, project, start, request }) => {
  const before = await readdir(root), cancelled = start(project)
  cancelled.cancel(); await assert.rejects(cancelled.promise, { name: 'AbortError' })
  assert.deepEqual(await readdir(root), before)
  const failed = start(project, undefined, undefined, (value, issued) => value.kind === 'prepare-vst-plan'
    ? Promise.reject(new Error('Worker fatal before final result')) : request(value, issued))
  await assert.rejects(failed.promise, /Worker fatal/)
  assert.deepEqual(await readdir(root), before)
}))

test('independent SMF2 patterns and SMPTE sources render full performances while original source clocks control trims', () => fixture(async ({ project, start, calls }) => {
  const chunk = (name, bytes) => { const h = Buffer.alloc(8); h.write(name); h.writeUInt32BE(bytes.length, 4); return Buffer.concat([h, Buffer.from(bytes)]) }
  const track = pitch => [0, 0x90, pitch, 100, 0x83, 0x60, 0x80, pitch, 0, 0, 0xff, 0x2f, 0]
  const document = (tracks, format, division) => {
    const header = Buffer.alloc(6); header.writeUInt16BE(format); header.writeUInt16BE(tracks.length, 2); header.writeUInt16BE(division, 4)
    return importMidiSource(Buffer.concat([chunk('MThd', header), ...tracks.map(bytes => chunk('MTrk', bytes))]), { sound })
  }
  project = { ...project, clips: project.clips.filter(clip => clip.asset !== 'v') }
  for (const [id, source] of [['patterns', document([track(60), track(67)], 2, 480)], ['smpte', document([track(64)], 0, (256 - 29) * 256 + 80)]]) {
    project = editArrangement(project, { kind: 'asset-add', asset: { id, kind: 'midi', name: id, source } })
    for (const pattern of id === 'patterns' ? [0, 1] : [undefined]) project = editArrangement(project, { kind: 'region-add', name: id,
      asset: id, lane: 'lane-2', position: 0, offset: 1, extent: 478, repeat: 3, ...(pattern === undefined ? {} : { pattern }) })
  }
  const before = structuredClone(project), result = await start(project).promise, plan = JSON.parse(await readFile(result.path))
  assert.equal(calls.length, 3); assert.equal(new Set(calls.map(call => call.output_path)).size, 3)
  const derived = plan.regions.filter(region => region.sourceClock)
  assert.equal(derived.length, 3)
  assert.equal(derived[2].sourceClock.denominator, '2400000'); assert.equal(derived[2].sourceClock.start, '1001')
  const rendered = await Promise.all(calls.map(async call => midiSourcePattern(importMidiSource(await readFile(call.midi_path)))) )
  assert.deepEqual(rendered.map(performance => performance.notes[0].pitch), [60, 67, 64])
  assert.deepEqual(project, before)
}))

test('a MIDI-only residual loop keeps absolute repeated source spans under the derived audio master', () => fixture(async ({ project, start }) => {
  project = { ...project, clips: project.clips.filter(clip => clip.asset === 'v'), playbackLoop: { start: 480, end: 960 } }
  project = editArrangement(project, { kind: 'asset-add', asset: { ...project.assets[1], id: 'external', name: 'External' } })
  project = editArrangement(project, { kind: 'region-add', name: 'External', asset: 'external', lane: 'lane-2', position: 0, offset: 0, extent: 480, repeat: 4 })
  const result = await start(project, { kind: 'mixed', output: 'AudioUID', portBindings: [{ asset: 'external', port: 0, destination: '-42' }] }).promise
  const plan = JSON.parse(await readFile(result.path))
  assert.equal(plan.midi.regions.length, 1); assert.equal(plan.midi.regions[0].startSeconds, 0)
  assert.equal(plan.midi.regions[0].sourceStart, 0); assert.equal(plan.midi.regions[0].sourceEnd, .5)
  assert.equal(plan.midi.regions[0].repeatCount, 4); assert.equal(plan.midi.duration, 2)
  assert.equal(plan.duration, .25); assert.equal(result.originSeconds, .25)
}))

test('derived VST voices compose with captured paired WAV/UMP without changing captured identity, clocks or packets', () => fixture(async ({ root, project, start }) => {
  const input = join(root, 'capture'); await mkdir(input)
  const origin = '1000000000', manifest = { schemaVersion: 1, state: 'recorded', failure: null,
    audio: 'audio.wav', audioBlocks: 'audio-blocks.jsonl', midi: 'midi.ump.jsonl', sampleRate: 48000, channels: 1,
    audioFrames: '4800', midiPacketCount: '2', input: { id: 'interface', name: 'Interface' }, midiSources: [{ id: 'keys', name: 'Keys' }],
    clock: { kind: 'mach-host-time', numer: 125, denom: 3, requestedStart: origin, firstAudioHostTime: origin } }
  const packets = [{ kind: 'midi', protocol: 2, source: 'keys', hostTime: origin, timestampOrigin: 'packet', words: [0x20903c64] },
    { kind: 'midi', protocol: 2, source: 'keys', hostTime: '1001920000', timestampOrigin: 'packet', words: [0x20803c00] }]
  await writeFile(join(input, 'session.json'), JSON.stringify(manifest))
  await writeFile(join(input, 'audio.wav'), wave(4800, 48000, 1))
  await writeFile(join(input, 'audio-blocks.jsonl'), JSON.stringify({ kind: 'audio', hostTime: origin,
    deviceSampleTime: '0', frameOffset: '0', frameCount: 4800, peaks: [[0, .1]] }) + '\n')
  await writeFile(join(input, 'midi.ump.jsonl'), packets.map(packet => JSON.stringify(packet)).join('\n') + '\n')
  const imported = await importArrangementCapture(project, input, { projectPath: join(root, 'song.json') })
  project = editArrangement(imported.project, { kind: 'lane-add', sourceKind: 'capture', name: 'Capture' })
  project = editArrangement(project, { kind: 'region-add', name: 'Paired', asset: imported.asset, lane: 'lane-3', position: 0,
    offset: '0', extent: '2400000', repeat: 3 })
  const before = structuredClone(project)
  const result = await start(project, { kind: 'mixed', output: 'AudioUID', portBindings: [],
    sourceBindings: [{ asset: imported.asset, source: 'keys', destination: '-42' }] }).promise
  const plan = JSON.parse(await readFile(result.path)), audio = plan.regions.find(region => region.captureClock)
  assert.equal(plan.kind, 'capture-arrangement'); assert.equal(plan.umpRegions.duration, plan.duration)
  assert.equal(audio.id, plan.umpRegions.regions[0].id); assert.equal(audio.asset, imported.asset)
  assert.equal(audio.captureClock.offset, plan.umpRegions.regions[0].offset)
  assert.equal(audio.captureClock.extent, plan.umpRegions.regions[0].extent)
  assert.deepEqual(plan.umpRegions.sources[0].timeline.packets, packets)
  assert.equal(plan.regions.filter(region => region.sourceClock).length, 2)
  assert.deepEqual(project, before)
}))
