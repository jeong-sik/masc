import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { readFile, writeFile, readdir, access } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { createHash } from 'node:crypto'
import { practiceSourceFixture } from './helpers/practice-source-fixture.mjs'
import { importArrangementPractice, saveArrangement, loadArrangement } from '../arrangement-files.mjs'
import { arrangementEditor, arrangementCommand, arrangementPracticePass } from '../arrangement-editor.mjs'
import { newArrangement, editArrangement } from '../arrangement.mjs'
import { arrangementRoute, arrangementPlaybackRequest, selectArrangementRoute } from '../arrangement-playback.mjs'
import { startSoundArrangement } from '../arrangement-sound.mjs'
import { phraseBacking } from '../phrase-backing.mjs'
const hash = bytes => createHash('sha256').update(bytes).digest('hex')
const json = async path => JSON.parse(await readFile(path, 'utf8'))
function wave(frames, rate) {
  const bytes = Buffer.alloc(44 + frames * 8)
  bytes.write('RIFF'); bytes.writeUInt32LE(bytes.length - 8, 4); bytes.write('WAVEfmt ', 8); bytes.writeUInt32LE(16, 16)
  bytes.writeUInt16LE(3, 20); bytes.writeUInt16LE(2, 22); bytes.writeUInt32LE(rate, 24); bytes.writeUInt32LE(rate * 8, 28)
  bytes.writeUInt16LE(8, 32); bytes.writeUInt16LE(32, 34); bytes.write('data', 36); bytes.writeUInt32LE(frames * 8, 40)
  return bytes
}
async function fixture(run, configure) {
  await practiceSourceFixture(async original => {
    const { root, input, rows, publish } = original
    await configure?.(original)
    rows[0].packet.words[0] &= 0xffffff00; rows[0].packet.words[1] = 0x90010000; await publish()
    const path = join(root, 'project', 'song.json'), imported = await importArrangementPractice(newArrangement({ tempo: 120.1 }), input, { projectPath: path })
    const editor = arrangementCommand(arrangementEditor(imported.project), 'region asset-1 .5 1 48000 3').editor
    const worker = new Worker(new URL('../arrangement-worker.mjs', import.meta.url)), jobs = new Map(), calls = [], owners = []
    let sequence = 0
    worker.on('message', row => { const job = jobs.get(row.id); jobs.delete(row.id); if (row.ok) job?.resolve(row.result); else job?.reject(new Error(row.error)) })
    worker.on('error', error => { for (const job of jobs.values()) job.reject(error) })
    const request = (value, issued) => new Promise((resolve, reject) => { const id = ++sequence; jobs.set(id, { resolve, reject }); issued?.(id); worker.postMessage({ ...value, id }) })
    const cancelRequest = request => worker.postMessage({ kind: 'cancel', request })
    const render = value => ({ cancel() {}, promise: (async () => {
      calls.push(value); const timelineBytes = await readFile(value.frames_path), timeline = JSON.parse(timelineBytes)
      assert.equal(hash(timelineBytes), value.expected_timeline_sha256)
      assert.equal(hash(await readFile(value.preset_path)), original.context.project.sound.preset.sha256)
      const bytes = wave(Number(timeline.frames), timeline.sampleRate); await writeFile(value.output_path, bytes, { flag: 'wx' })
      return { output_path: value.output_path, timeline_sha256: hash(timelineBytes), preset_sha256: original.context.project.sound.preset.sha256,
        instrument: original.context.project.sound.instrument, sample_rate: timeline.sampleRate, frames: Number(timeline.frames), wav_sha256: hash(bytes) }
    })() })
    const start = (project = editor.project, route = arrangementRoute({ output: 'Audio' }), selectedRun = render) => {
      const owner = startSoundArrangement({ project, route, sourceRoot: dirname(path), directory: root, request, cancelRequest, run: selectedRun }); owners.push(owner); return owner
    }
    try { await run({ ...original, path, project: editor.project, calls, request, start, render }) }
    finally { await Promise.allSettled(owners.map(owner => owner.dispose())); await worker.terminate() }
  })
}

test('captured sound route derives sample-frame VST input without changing raw UMP or source-native cuts', () => fixture(async ({ root, path, project, rows, calls, start, context }) => {
  const before = structuredClone(project), prepared = await start().promise, plan = await json(prepared.path), call = calls[0]
  assert.equal(calls.length, 1); assert.equal(call.midi_path, undefined); assert.equal(call.sample_rate, 48000)
  const timeline = await json(call.frames_path)
  assert.equal(timeline.kind, 'practice-vst'); assert.deepEqual(timeline.events.map(event => event.frame), ['0', '0', '0', '5', '49'])
  assert.deepEqual(timeline.events.map(event => event.bytes), [...context.backing.initial, [0xb0 | context.backing.channel, 74, 85], [0x90 | context.backing.channel, 60, 72], [0x80 | context.backing.channel, 60, 9]])
  const clip = plan.regions[0]
  assert.deepEqual(clip.sourceClock, { start: '125', end: '6000125', denominator: '3000000000' })
  assert.equal(clip.offsetFrames, 1); assert.equal(clip.frameCount, 96); assert.equal(clip.repeat, 3)
  assert.equal(plan.kind, 'wave-arrangement'); assert.equal(plan.assets[0].sampleRate, 48000)
  assert.deepEqual(project, before); assert.equal(rows[0].packet.hostTime, '18446744073709002400')
  const saved = join(root, 'portable', 'song.json'); await saveArrangement(saved, project, null, { sourceRoot: dirname(path) })
  assert.deepEqual((await loadArrangement(saved)).project, before)
}))

test('fractional host cuts reach both actual VST and raw worker plans, survive save and return to whole-tick trims', () => fixture(async ({ root, path, project, start, request }) => {
  let editor = arrangementEditor(project)
  editor = arrangementCommand(editor, 'select region-1').editor
  editor = arrangementCommand(editor, 'trim-fraction 3 4800000 7').editor
  const selected = editor.project, prepared = await start(selected).promise, plan = await json(prepared.path)
  assert.deepEqual(plan.regions[0].sourceClock, { start: '375', end: '600000375', denominator: '21000000000' })
  assert.equal(plan.regions[0].offsetFrames, 1); assert.equal(plan.regions[0].frameCount, 1371)
  const raw = await request({ kind: 'prepare-capture', project: selected, sourceRoot: dirname(path), directory: root, midiOutput: '42' })
  const external = await json(raw.path), clip = external.umpRegions.regions[0]
  assert.equal(clip.offset, '3'); assert.equal(clip.extent, '4800000'); assert.equal(clip.sourceDivisor, '7')
  assert.deepEqual(external.umpRegions.sources[0].timeline.clock, { origin: '18446744073708999999', numer: 125, denom: 3 })
  const saved = join(root, 'fractional/song.json'); await saveArrangement(saved, selected, null, { sourceRoot: dirname(path) })
  assert.deepEqual((await loadArrangement(saved)).project, selected)
  editor = arrangementCommand(editor, 'duplicate 8').editor
  assert.ok(editor.project.clips.every(clip => clip.sourceDivisor === '7'))
  editor = arrangementCommand(editor, 'trim 1 48000').editor
  assert.equal(editor.project.clips.at(-1).sourceDivisor, undefined)
  editor = arrangementCommand(editor, 'undo').editor; assert.equal(editor.project.clips.at(-1).sourceDivisor, '7')
  const added = arrangementCommand(editor, 'practice-region asset-1 12 3 4800000 7 2000000').editor.project.clips.at(-1)
  assert.equal(added.sourceDivisor, '7'); assert.equal(added.repeat, 2000000)
  for (const command of ['trim-fraction 0 1 0', 'trim-fraction 0 1 01', 'trim-fraction 0 16800008 7', 'practice-region missing 0 1 2 3']) assert.throws(() => arrangementCommand(editor, command))
}))

test('an original partial practice pass reaches the actual VST worker source clock', () => fixture(async ({ root, path, project, request, start }) => {
  let editor = arrangementCommand(arrangementEditor(project), 'select region-1').editor
  const target = arrangementCommand(editor, 'practice-pass 1 asset-1').effect
  const selected = await request({ ...target, project: editor.project, sourceRoot: dirname(path), directory: root })
  assert.equal(selected.full, false)
  assert.deepEqual(selected.cut, { offset: '1', extent: '2400000', sourceDivisor: '1' })
  editor = arrangementPracticePass(editor, target, selected)
  const prepared = await start(editor.project).promise, plan = await json(prepared.path)
  const region = plan.regions.at(-1)
  assert.deepEqual(region.sourceClock, { start: '125', end: '300000125', denominator: '3000000000' })
  assert.equal(region.offsetFrames, 1); assert.equal(region.frameCount, 4800)
}))

test('captured track controls precede same-frame raw overrides in the actual worker render input', () => fixture(async ({ project, rows, calls, start, context }) => {
  const original = structuredClone(rows), before = structuredClone(project)
  await start().promise
  const timeline = await json(calls[0].frames_path), channel = context.backing.channel
  assert.deepEqual(timeline.events, [
    { frame: '0', bytes: [0xb0 | channel, 7, 23] },
    { frame: '0', bytes: [0xb0 | channel, 10, 100] },
    { frame: '0', bytes: [0xb0 | channel, 7, 85] },
    { frame: '0', bytes: [0xb0 | channel, 10, 17] },
    { frame: '5', bytes: [0x90 | channel, 60, 72] },
    { frame: '49', bytes: [0x80 | channel, 60, 9] },
  ])
  assert.deepEqual(rows, original); assert.deepEqual(project, before)
}, ({ context, rows }) => {
  const track = context.project.tracks.find(track => track.id === context.track)
  track.level = 23; track.pan = 100
  context.backing = phraseBacking(context.project, context.track, true)
  rows[1].packet.words = [0x23b50755, 0x23b50a11]
}))

test('loop and count-in keep exact original raw source periods under the derived audio master', () => fixture(async ({ project, start }) => {
  const looped = { ...project, playbackLoop: { start: 480, end: 1440 }, practice: { countInBars: 1, metronome: true } }
  const result = await start(looped).promise, plan = await json(result.path), voice = plan.regions.find(region => region.sourceClock)
  assert.equal(voice.projectTick, 480); assert.equal(voice.startSeconds, 480 / 960 * 60 / 120.1)
  assert.equal(voice.sourceClock.end, '6000125'); assert.equal(plan.practice.loop.countInBeats, '4')
  assert.equal(plan.regions.filter(region => region.pulseClock).length, 2)
}))

test('explicit raw source override stays external and an unused override fails before opening a VST', () => fixture(async ({ project, calls, start }) => {
  const editor = arrangementEditor(project), route = selectArrangementRoute(arrangementRoute({ output: 'Audio' }), arrangementCommand(editor, 'midi-source asset-1 10 42').effect)
  assert.equal(arrangementPlaybackRequest(project, route).kind, 'prepare-capture')
  const invalid = { ...route, sourceBindings: [{ asset: 'asset-1', source: 'other', destination: '42' }] }
  assert.equal(arrangementPlaybackRequest(project, invalid).kind, 'prepare-capture')
  await assert.rejects(start(project, invalid).promise, /No audible local instrument/); assert.equal(calls.length, 0)
}))

test('unsupported attributed UMP fails projection before a child opens; failed preparation cleans its owned root', () => fixture(async ({ root, input, rows, publish, project, path, calls, start }) => {
  rows[0].packet.words[0] |= 3; await publish()
  const imported = await importArrangementPractice(newArrangement(), input, { projectPath: path })
  const candidate = arrangementCommand(arrangementEditor(imported.project), 'place asset-1 0').editor.project
  const before = await readdir(root), owner = start(candidate)
  await assert.rejects(owner.promise, /attributes/); assert.equal(calls.length, 0); assert.deepEqual(await readdir(root), before)
}))

test('local captured sound and externally routed raw take share the native clock with complete source bindings', () => fixture(async ({ project, start, calls }) => {
  project = editArrangement(project, { kind: 'asset-add', asset: { ...project.assets[0], id: 'external', name: 'External raw' } })
  project = editArrangement(project, { kind: 'region-add', name: 'External', asset: 'external', lane: 'lane-1', position: 0, offset: '0', extent: '48000', repeat: 2 })
  const route = { kind: 'mixed', output: 'Audio', sourceBindings: [{ asset: 'external', source: '10', destination: '42' }] }
  const prepared = await start(project, route).promise, plan = await json(prepared.path)
  assert.equal(calls.length, 1); assert.equal(plan.kind, 'capture-arrangement')
  assert.equal(plan.regions.filter(region => region.sourceClock).length, 1)
  assert.equal(plan.umpRegions.sources[0].id, 'external'); assert.equal(plan.umpRegions.regions[0].repeatCount, 2)
  assert.deepEqual(prepared.bindings, [{ port: 0, destination: '42' }])
  const before = calls.length
  const bad = { ...route, sourceBindings: [{ asset: 'external', source: 'unused', destination: '42' }] }
  await assert.rejects(start(project, bad).promise, /unused/); assert.equal(calls.length, before)
}))

test('an end-boundary projected event gets one private guard sample without extending the original source span', () => fixture(async ({ root, input, rows, arm, publish, path, start, calls }) => {
  // Put a final controller just before the render source end: its exact ceil
  // sample lies on the full source's after-frame boundary.
  rows[2].packet.words = [0x43b54a00, 0x80000000]
  arm.renderClock.anchor.hostTime = '9007199254740993123'
  rows[0].packet.hostTime = String(BigInt(arm.renderClock.anchor.hostTime) + 2400n)
  rows[2].packet.hostTime = String(BigInt(arm.renderClock.anchor.hostTime) + 2399999n)
  const { nominalMidiFrame } = await import('../render-midi-clock.mjs')
  rows[1].packet.hostTime = arm.renderClock.anchor.hostTime
  for (const row of rows) row.nominalFrame = nominalMidiFrame(row.packet.hostTime, arm.input.clock, arm.renderClock)
  await publish()
  const imported = await importArrangementPractice(newArrangement(), input, { projectPath: path })
  const project = arrangementCommand(arrangementEditor(imported.project), 'place asset-1 0').editor.project
  const result = await start(project).promise, plan = await json(result.path), timeline = await json(calls[0].frames_path)
  assert.equal(plan.regions[0].frameCount, 4800); assert.equal(timeline.frames, '4801')
  assert.equal(plan.assets[0].frames, 4801)
  assert.equal(plan.regions[0].sourceClock.end, '300000000')
}))

test('cancel retains timeline, preset and render root until native close, then rejects late success and removes the lease', () => fixture(async ({ root, start }) => {
  let enter, close, cancelled = 0
  const entered = new Promise(resolve => { enter = resolve }), terminal = new Promise(resolve => { close = resolve })
  const owner = start(undefined, undefined, value => { enter(value); return { promise: terminal, cancel() { cancelled++ } } })
  const call = await Promise.race([entered, owner.promise.then(() => { throw new Error('Render was not intercepted') })]), directory = dirname(call.output_path)
  owner.cancel(); const disposed = owner.dispose(); let settled = false; disposed.then(() => { settled = true })
  await new Promise(resolve => setImmediate(resolve)); assert.equal(settled, false); assert.ok(cancelled > 0)
  await access(call.frames_path); await access(call.preset_path)
  close({ preset_sha256: hash(await readFile(call.preset_path)) }); await assert.rejects(owner.promise); await disposed
  await assert.rejects(access(directory), { code: 'ENOENT' })
}))
