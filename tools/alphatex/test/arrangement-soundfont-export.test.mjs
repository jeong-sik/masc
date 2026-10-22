import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, writeFile, readdir, access, rm } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { newArrangement, editArrangement } from '../arrangement.mjs'
import { midiSourceFromEvents } from '../midi-source.mjs'
import { captureFluidSound } from '../soundfont.mjs'
import { prepareArrangementSound } from '../arrangement-sound.mjs'
import { exportArrangementWave } from '../arrangement-export.mjs'
import { nativeJob } from '../vst.mjs'

const host = fileURLToPath(new URL('../soundfont_host.py', import.meta.url))
const actualFluid = request => nativeJob(request, { command: 'python3', args: [host], label: 'SoundFont' })
const gate = () => { let resolve; const promise = new Promise(yes => { resolve = yes }); return { promise, resolve } }
let font
const sound = () => font ??= captureFluidSound().promise
function document(sound, ids = ['fluid']) {
  let project = editArrangement(newArrangement({ tempo: 120 }), { kind: 'lane-add', sourceKind: 'midi', name: 'Keys' })
  for (const id of ids) {
    const source = midiSourceFromEvents([
      { tick: 0, kind: 'meta', type: 33, data: [0] }, { tick: 0, kind: 'channel', bytes: [0x90, 60, 100] },
      { tick: 0, kind: 'meta', type: 33, data: [1] }, { tick: 0, kind: 'channel', bytes: [0x90, 67, 90] },
      { tick: 480, kind: 'meta', type: 33, data: [0] }, { tick: 480, kind: 'channel', bytes: [0x80, 60, 0] },
      { tick: 960, kind: 'meta', type: 33, data: [1] }, { tick: 960, kind: 'channel', bytes: [0x80, 67, 0] },
      { tick: 1920, kind: 'meta', type: 47, data: [] },
    ], { ppq: 960, sound })
    project = editArrangement(project, { kind: 'asset-add', asset: { id, kind: 'midi', name: id, source } })
    project = editArrangement(project, { kind: 'region-add', asset: id, lane: 'lane-1', name: id,
      position: 1, offset: 1, extent: 478, repeat: 3 })
  }
  return project
}
function wave() {
  const bytes = Buffer.alloc(60)
  bytes.write('RIFF'); bytes.writeUInt32LE(52, 4); bytes.write('WAVEfmt ', 8); bytes.writeUInt32LE(16, 16)
  bytes.writeUInt16LE(3, 20); bytes.writeUInt16LE(1, 22); bytes.writeUInt32LE(44100, 24); bytes.writeUInt32LE(176400, 28)
  bytes.writeUInt16LE(4, 32); bytes.writeUInt16LE(32, 34); bytes.write('data', 36); bytes.writeUInt32LE(16, 40)
  return bytes
}
const fakeMix = async (plan, path) => {
  await writeFile(path, wave())
  return { kind: 'rendered', path, sampleRate: 44100, channels: 1, frames: 4, peak: 0 }
}

test('offline export uses the actual frozen SoundFont and source clock, excluding loop and click without changing MIDI', async () => {
  const root = await mkdtemp(join(tmpdir(), 'masc-fluid-export-'))
  try {
    const selected = await sound(), project = { ...document(selected), playbackLoop: { start: 240, end: 960 },
      practice: { countInBars: 1, metronome: true } }, before = structuredClone(project)
    let combined, renders = 0
    await exportArrangementWave(project, join(root, 'mix.wav'), { directory: root, sourceRoot: root,
      prepareSound: (project, options) => prepareArrangementSound(project, { ...options,
        runSoundfont(request) { renders++; assert.equal(request.plan.font.sha256, selected.font.sha256); return actualFluid(request) } }),
      prepareVst() { throw new Error('A SoundFont must never fall through to VST') },
      render: async (path, output) => { combined = JSON.parse(await readFile(path)); return fakeMix(path, output) } })
    assert.equal(renders, 1); assert.equal(combined.assets.length, 1)
    assert.equal(combined.assets[0].realization.fontSha256, selected.font.sha256)
    assert.deepEqual([...new Set(combined.assets[0].realization.timing.events.map(event => event[0]))], [0, 1])
    assert.deepEqual(combined.regions[0].sourceClock, { start: '500000', end: '239500000', denominator: '960000000' })
    assert.equal(combined.regions[0].repeat, 3); assert.equal(combined.regions[0].exportStartFrame, 22)
    assert.equal(combined.loop, undefined); assert.equal(combined.practice, undefined)
    assert.deepEqual(project, before); assert.deepEqual(await readdir(root), ['mix.wav'])
  } finally { await rm(root, { recursive: true, force: true }) }
})

test('cancelling a later SoundFont export joins its child before deleting the first render and frozen font', async () => {
  const root = await mkdtemp(join(tmpdir(), 'masc-fluid-export-cancel-'))
  try {
    const controller = new AbortController(), entered = gate(), closed = gate()
    let renders = 0, cancels = 0, settled = false
    const pending = exportArrangementWave(document(await sound(), ['first', 'second']), join(root, 'mix.wav'), {
      directory: root, sourceRoot: root, signal: controller.signal, render: fakeMix,
      prepareSound: (project, options) => prepareArrangementSound(project, { ...options,
        runSoundfont(request) {
          if (++renders === 1) return actualFluid(request)
          entered.resolve(request); return { promise: closed.promise, cancel() { cancels++ } }
        } }) })
    const rejected = assert.rejects(pending, { name: 'AbortError' }).then(() => { settled = true })
    const request = await entered.promise, preparationRoot = dirname(dirname(request.plan.font.path))
    controller.abort(); await new Promise(resolve => setImmediate(resolve))
    assert.equal(settled, false); assert.ok(cancels > 0)
    await access(request.plan.font.path)
    const retained = (await readdir(preparationRoot)).filter(name => name.endsWith('.wav'))
    assert.equal(retained.length, 1); await access(join(preparationRoot, retained[0]))
    closed.resolve({}); await rejected
    assert.deepEqual(await readdir(root), [])
  } finally { await rm(root, { recursive: true, force: true }) }
})

test('a changed engine refuses export and preserves existing user output with no fallback or retained private files', async () => {
  const root = await mkdtemp(join(tmpdir(), 'masc-fluid-export-refusal-'))
  try {
    const selected = await sound(), changed = { ...selected, engine: { ...selected.engine, version: 'unavailable-engine-version' } }
    const target = join(root, 'mix.wav'), old = Buffer.from('existing user output')
    await writeFile(target, old)
    await assert.rejects(exportArrangementWave(document(changed), target, { directory: root, sourceRoot: root,
      render() { throw new Error('An invalid sound must not reach the mixer') } }), /version|engine/i)
    assert.deepEqual(await readFile(target), old); assert.deepEqual(await readdir(root), ['mix.wav'])
  } finally { await rm(root, { recursive: true, force: true }) }
})
