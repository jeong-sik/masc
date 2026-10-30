import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { readFile, writeFile, readdir, access } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { createHash } from 'node:crypto'
import { practiceSourceFixture } from './helpers/practice-source-fixture.mjs'
import { importArrangementPractice, saveArrangement, loadArrangement } from '../arrangement-files.mjs'
import { arrangementEditor, arrangementCommand, arrangementAction, arrangementPracticeSound } from '../arrangement-editor.mjs'
import { newArrangement, editArrangement } from '../arrangement.mjs'
import { arrangementRoute } from '../arrangement-playback.mjs'
import { startSoundArrangement } from '../arrangement-sound.mjs'
import { captureFluidSound } from '../soundfont.mjs'
import { nominalMidiFrame } from '../render-midi-clock.mjs'
import { practiceRange } from '../practice-source.mjs'
import { readWaveMetadata } from '../wave-file.mjs'

const hash = bytes => createHash('sha256').update(bytes).digest('hex')
const json = async path => JSON.parse(await readFile(path, 'utf8'))
let captured
const sound = () => captured ??= captureFluidSound().promise
async function fixture(run) {
  await practiceSourceFixture(async original => {
    const { root, input, context, arm, rows, receipt, publish } = original
    context.project.tracks[0].program = 33
    arm.renderClock.anchor.hostTime = '9007199254740993123'
    rows[1].packet.hostTime = String(BigInt(arm.renderClock.anchor.hostTime) - 1n)
    // The declared monitor projection ignores raw bank/program, then retains
    // the ordinary CC74 override. Those original words stay in the source.
    rows[1].packet.words = [0x23b5007f, 0x23c56200, 0x23b54a55]
    rows[0].packet.words[0] &= 0xffffff00; rows[0].packet.words[1] = 0x90010000
    rows[0].packet.hostTime = String(BigInt(arm.renderClock.anchor.hostTime) + 24000000n)
    rows[2].packet.hostTime = String(BigInt(arm.renderClock.anchor.hostTime) + 48000000n)
    receipt.monitorFinal.pcm.final.renderedFrames = '144000'
    receipt.monitorFinal.pcm.final.admittedFrames = receipt.monitorFinal.pcm.sentFrames = '145024'
    const refresh = async () => {
      for (const row of rows) row.nominalFrame = nominalMidiFrame(row.packet.hostTime, arm.input.clock, arm.renderClock)
      await publish()
    }
    await refresh()
    const path = join(root, 'project', 'song.json')
    const imported = await importArrangementPractice(newArrangement(), input, { projectPath: path })
    const worker = new Worker(new URL('../arrangement-worker.mjs', import.meta.url)), jobs = new Map(), owners = []
    let sequence = 0
    worker.on('message', row => { const job = jobs.get(row.id); jobs.delete(row.id); if (row.ok) job?.resolve(row.result); else job?.reject(new Error(row.error)) })
    worker.on('error', error => { for (const job of jobs.values()) job.reject(error) })
    const request = (value, issued) => new Promise((resolve, reject) => { const id = ++sequence; jobs.set(id, { resolve, reject }); issued?.(id); worker.postMessage({ ...value, id }) })
    const start = (project, extra = {}) => {
      const owner = startSoundArrangement({ project, route: arrangementRoute({ output: 'Audio' }), sourceRoot: dirname(path), directory: root,
        request, cancelRequest: request => worker.postMessage({ kind: 'cancel', request }), ...extra })
      owners.push(owner); return owner
    }
    try { await run({ ...original, path, imported, request, start, refresh }) }
    finally { await Promise.allSettled(owners.map(owner => owner.dispose())); await worker.terminate() }
  })
}

test('practice sound choice, undo/reset and portable reopen retain all original capture identities and bytes', () => fixture(async ({ root, path, imported, files }) => {
  const original = structuredClone(imported.project), sourceBytes = await Promise.all(Object.values(files).map(path => readFile(path)))
  let editor = arrangementEditor(original)
  const effect = arrangementCommand(editor, 'practice-soundfont asset-1 /a font.sf2').effect
  assert.deepEqual(effect, { kind: 'practice-soundfont', asset: 'asset-1', path: '/a font.sf2' })
  editor = arrangementPracticeSound(editor, effect.asset, await sound())
  const selected = structuredClone(editor.project)
  assert.deepEqual(selected.assets[0].parts, original.assets[0].parts)
  assert.deepEqual(selected.assets[0].metadata, original.assets[0].metadata)
  editor = arrangementAction(editor, { kind: 'undo' }); assert.deepEqual(editor.project, original)
  editor = arrangementAction(editor, { kind: 'redo' }); assert.deepEqual(editor.project, selected)
  editor = arrangementCommand(editor, 'practice-sound-original asset-1').editor; assert.deepEqual(editor.project, original)
  editor = arrangementAction(editor, { kind: 'undo' }); assert.deepEqual(editor.project, selected)
  const saved = join(root, 'portable', 'song.json')
  await saveArrangement(saved, selected, null, { sourceRoot: dirname(path) })
  assert.deepEqual((await loadArrangement(saved)).project, selected)
  assert.deepEqual(await Promise.all(Object.values(files).map(path => readFile(path))), sourceBytes)
  for (const invalid of [{ kind: 'soundfont' }, { ...await sound(), font: { ...((await sound()).font), sha256: '0'.repeat(64) } }]) {
    assert.throws(() => arrangementPracticeSound(editor, 'asset-1', invalid))
    assert.deepEqual(editor.project, selected)
  }
  assert.throws(() => arrangementCommand(editor, 'practice-soundfont missing'))
  assert.throws(() => arrangementCommand(editor, 'practice-sound-original missing'))
}))

test('actual worker and FluidSynth realize full practice history at its original rate with exact cuts and mixed WAV', () => fixture(async ({ root, path, imported, start, request, context }) => {
  let editor = arrangementPracticeSound(arrangementEditor(imported.project), 'asset-1', await sound())
  editor = arrangementCommand(editor, 'practice-region asset-1 0 24000001 24000000 1 3').editor
  const bytes = Buffer.alloc(44 + 4800 * 2)
  bytes.write('RIFF'); bytes.writeUInt32LE(bytes.length - 8, 4); bytes.write('WAVEfmt ', 8); bytes.writeUInt32LE(16, 16)
  bytes.writeUInt16LE(1, 20); bytes.writeUInt16LE(1, 22); bytes.writeUInt32LE(48000, 24); bytes.writeUInt32LE(96000, 28)
  bytes.writeUInt16LE(2, 32); bytes.writeUInt16LE(16, 34); bytes.write('data', 36); bytes.writeUInt32LE(bytes.length - 44, 40)
  const wave = join(root, 'input.wav'); await writeFile(wave, bytes)
  const added = await request({ kind: 'import-wave', project: editor.project, path: wave, projectPath: path })
  editor = arrangementCommand(arrangementEditor(added.project), `place ${added.asset} 0`).editor
  const before = structuredClone(editor.project), prepared = await start(before).promise, plan = await json(prepared.path)
  assert.deepEqual(editor.project, before)
  const asset = plan.assets.find(asset => asset.realization?.kind === 'soundfont'), region = plan.regions.find(region => region.asset === asset.id)
  const sourcePlan = await json(join(dirname(prepared.path), asset.path.split('/').at(-1).replace('.wav', '.json')))
  assert.equal(asset.sampleRate, 48000); assert.equal(sourcePlan.sampleRate, 48000)
  assert.equal(asset.realization.fontSha256, (await sound()).font.sha256)
  assert.deepEqual(sourcePlan.ports[0].events.map(event => event.bytes), [[0xc0,33], ...context.backing.initial, [0xb0,74,85], [0x90,60,72], [0x80,60,9]])
  assert.deepEqual(sourcePlan.ports[0].events.map(event => event.frame), [0,0,0,0,48001,96001])
  assert.deepEqual(region.sourceClock, { start: '3000000125', end: '6000000125', denominator: '3000000000' })
  assert.equal(region.offsetFrames, 48001); assert.equal(region.frameCount, 48000); assert.equal(region.repeat, 3)
  assert.equal(plan.assets.length, 2); assert.equal(plan.regions.length, 2)
  const metadata = await readWaveMetadata(asset.path), pcm = await readFile(asset.path)
  let nonzero = false
  for (let i = metadata.dataOffset; i < metadata.dataOffset + metadata.dataBytes; i += 4) {
    const value = pcm.readFloatLE(i); assert.ok(Number.isFinite(value)); nonzero ||= value !== 0
  }
  assert.ok(nonzero)
}))

test('a private final control-block guard preserves the original fractional host-clock region and repeat period', () => fixture(async ({ root, path, imported, rows, arm, input, refresh, start }) => {
  rows[2].packet.words = [0x43b54a00, 0x80000000]
  rows[2].packet.hostTime = String(BigInt(arm.renderClock.anchor.hostTime) + 72000000n)
  await refresh()
  const next = await importArrangementPractice(newArrangement(), input, { projectPath: path })
  let editor = arrangementPracticeSound(arrangementEditor(next.project), 'asset-1', await sound())
  editor = arrangementCommand(editor, 'practice-region asset-1 0 1 72000000 1 2').editor
  const prepared = await start(editor.project).promise, plan = await json(prepared.path), asset = plan.assets[0], region = plan.regions[0]
  const original = practiceRange(next.project.assets[0])
  assert.equal(original.extent, '72000002')
  assert.equal(asset.frames, 144065)
  assert.equal(region.frameCount, 144000); assert.equal(region.offsetFrames, 1); assert.equal(region.repeat, 2)
  assert.deepEqual(region.sourceClock, { start: '125', end: '9000000125', denominator: '3000000000' })
  assert.ok(asset.frames > region.offsetFrames + region.frameCount)
}))

test('explicit external routing overrides the new sound, and canceled native preparation joins before removing its font', () => fixture(async ({ root, imported, start }) => {
  let editor = arrangementPracticeSound(arrangementEditor(imported.project), 'asset-1', await sound())
  editor = arrangementCommand(editor, 'place asset-1 0').editor
  const selected = editor.project
  await assert.rejects(start(selected, { route: { kind: 'mixed', output: 'Audio', sourceBindings: [{ asset: 'asset-1', source: '10', destination: '42' }] } }).promise, /No audible local instrument/)
  let enter, close, cancelled = 0
  const entered = new Promise(resolve => { enter = resolve }), terminal = new Promise(resolve => { close = resolve })
  const before = await readdir(root)
  const owner = start(selected, { runSoundfont: value => { enter(value); return { promise: terminal, cancel() { cancelled++ } } } })
  const request = await Promise.race([entered, owner.promise.then(() => { throw new Error('Native request was not intercepted') })])
  await access(request.plan.font.path)
  owner.cancel(); const disposed = owner.dispose(); let settled = false; disposed.then(() => { settled = true })
  await new Promise(resolve => setImmediate(resolve)); assert.equal(settled, false); assert.ok(cancelled > 0)
  await access(request.plan.font.path)
  close({}); await assert.rejects(owner.promise); await disposed
  await assert.rejects(access(request.plan.font.path), { code: 'ENOENT' })
  assert.deepEqual(await readdir(root), before)
}))

test('unsupported raw attributes are refused before FluidSynth opens and do not alter the original sound choice', () => fixture(async ({ path, input, rows, refresh, start }) => {
  rows[0].packet.words[0] |= 3; await refresh()
  const imported = await importArrangementPractice(newArrangement(), input, { projectPath: path })
  let editor = arrangementPracticeSound(arrangementEditor(imported.project), 'asset-1', await sound())
  editor = arrangementCommand(editor, 'place asset-1 0').editor
  const before = structuredClone(editor.project)
  let calls = 0
  await assert.rejects(start(editor.project, { runSoundfont() { calls++; throw new Error('Unexpected native render') } }).promise, /attributes/)
  assert.equal(calls, 0); assert.deepEqual(editor.project, before)
}))
