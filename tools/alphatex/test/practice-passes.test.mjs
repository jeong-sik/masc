import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile, readdir, mkdir, chmod, writeFile, rm } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { once } from 'node:events'
import { Worker } from 'node:worker_threads'
import { practiceSourceFixture } from './helpers/practice-source-fixture.mjs'
import { phraseBacking, backingClock } from '../phrase-backing.mjs'
import { nominalMidiFrame } from '../render-midi-clock.mjs'
import { practiceRange } from '../practice-source.mjs'
import { newArrangement } from '../arrangement.mjs'
import { arrangementEditor, arrangementCommand, arrangementImported, arrangementPracticePass } from '../arrangement-editor.mjs'
import { importArrangementPractice, saveArrangement, loadArrangement, inspectPracticePasses } from '../arrangement-files.mjs'

// Independent original renderer arithmetic: two quarter-note beats at137 BPM.
const boundary = cycle => (cycle * 5292000n * 2n + 137n) / 274n
const hostDelta = frame => frame * 80000n / 147n
const json = async path => JSON.parse(await readFile(path, 'utf8'))
async function fixture(run, { anchorFrame = 0n, frames = boundary(3n) + 123n, short = false } = {}) {
 await practiceSourceFixture(async data => {
  const { root, context, arm, rows, receipt, publish, input } = data
  context.project.tempo = 137; context.project.loop = { start: 960, end: 2880 }
  context.project.tracks.push({ ...context.project.tracks[0], id: 'backing', channel: 1,
   notes: [{ id: 'n', pitch: 48, start: 960, duration: 960, velocity: 80 }] })
  context.backing = phraseBacking(context.project, context.track, true)
  Object.assign(arm.renderClock, { sampleRate: 44100, anchor: { frame: String(anchorFrame), hostTime: '18446744000000000000' } })
  receipt.monitorFinal.pcm.format.sampleRate = 44100
  Object.assign(receipt.monitorFinal.pcm.final, { renderedFrames: String(frames), admittedFrames: String(frames + 1024n) })
  receipt.monitorFinal.pcm.sentFrames = String(frames + 1024n)
  const deltas = short ? [-1n, 120n, 240n] : [hostDelta(boundary(1n)), hostDelta(boundary(1n)) + 1n, hostDelta(boundary(1n)) + 24000n]
  rows.forEach((row, index) => {
   row.packet.hostTime = String(BigInt(arm.renderClock.anchor.hostTime) + deltas[index])
   row.nominalFrame = nominalMidiFrame(row.packet.hostTime, arm.input.clock, arm.renderClock)
  })
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

test('actual worker selects absolute renderer passes, keeps rational boundary membership and portable comp edits', () => fixture(async ({ root, path, imported, directory, request, context, rows, files }) => {
 const source = imported.project.assets[0], originals = await Promise.all(Object.values(files).map(path => readFile(path)))
 let editor = arrangementCommand(arrangementEditor(imported.project), 'cursor 4').editor
 const inspect = arrangementCommand(editor, 'practice-passes').effect
 const summary = await request({ ...inspect, project: editor.project, sourceRoot: dirname(path), directory })
 assert.deepEqual([summary.firstPass, summary.lastPass, summary.count], ['1', '4', '4'])
 const choose = async number => {
  const target = arrangementCommand(editor, `practice-pass ${number}`).effect
  const selected = await request({ ...target, project: editor.project, sourceRoot: dirname(path), directory })
  editor = arrangementPracticePass(editor, target, selected); return selected
 }
 const one = await choose('1'); assert.equal(one.full, true)
 const before = editor.project, two = await choose('2'), clip = editor.project.clips[0]
 assert.equal(editor.project.clips.length, 1); assert.equal(clip.position, 3840); assert.equal(two.full, true)
 // Boundary1 is fractional in original host ticks; the floor packet belongs
 // before it, while ceil/inside packets belong to pass2. Original log unchanged.
 const range = practiceRange(source), divisor = BigInt(clip.sourceDivisor), offset = BigInt(clip.offset), extent = BigInt(clip.extent)
 const inside = rows.map(row => {
  const tick = (BigInt(row.packet.hostTime) - BigInt(range.origin)) * divisor
  return tick >= offset && tick < offset + extent
 })
 assert.deepEqual(inside, [false, true, true]); assert.notEqual(divisor, 1n)
 assert.equal(offset * 147n, boundary(1n) * 80000n * divisor)
 const raw = await request({ kind: 'prepare-capture', project: editor.project, sourceRoot: dirname(path), directory, midiOutput: '42' })
 const plan = await json(raw.path); assert.deepEqual(plan.umpRegions.sources[0].timeline.packets, rows.map(row => row.packet))
 assert.deepEqual(plan.umpRegions.regions.map(region => [region.offset, region.extent, region.sourceDivisor]), [[clip.offset, clip.extent, clip.sourceDivisor]])
 await rm(dirname(raw.path), { recursive: true })
 editor = arrangementCommand(editor, 'undo').editor; assert.deepEqual(editor.project, before)
 editor = arrangementCommand(editor, 'redo').editor
 const partial = await choose('4'); assert.equal(partial.full, false)
 assert.equal(BigInt(partial.cut.extent) * 147n, 123n * 80000n * BigInt(partial.cut.sourceDivisor))
 const saved = join(root, 'moved/song.json'); await saveArrangement(saved, editor.project, null, { sourceRoot: dirname(path) })
 assert.deepEqual((await loadArrangement(saved)).project, editor.project)
 assert.deepEqual(await Promise.all(Object.values(files).map(path => readFile(path))), originals)
 assert.deepEqual(await readdir(directory), [])
 // The actual producer uses absolute positions; adjacent pass frame lengths
 // differ. A repeated rounded cycle would not match these attacks.
 const produced = backingClock(context.backing, 44100).block('0', Number(boundary(3n) + 123n))
 assert.deepEqual(produced.filter(row => row.bytes[0] === 0x91).map(row => row.frame), [0, 1, 2, 3].map(cycle => Number(boundary(BigInt(cycle)))))
 assert.notEqual(boundary(2n), boundary(1n) * 2n)
}))

test('late render anchors retain original cycle numbers and partial source coverage', () => fixture(async ({ imported, path, directory, request }) => {
 const job = { kind: 'practice-passes', project: imported.project, asset: imported.asset, sourceRoot: dirname(path), directory }
 const summary = await request(job); assert.deepEqual([summary.firstPass, summary.lastPass, summary.count], ['3', '4', '2'])
 const third = await request({ ...job, kind: 'practice-pass', pass: '3' }); assert.equal(third.full, false); assert.equal(third.cut.offset, '0')
 const fourth = await request({ ...job, kind: 'practice-pass', pass: '4' }); assert.equal(fourth.full, false)
 await assert.rejects(request({ ...job, kind: 'practice-pass', pass: '1' }), /outside/)
}, { anchorFrame: boundary(2n) + 10n, short: true }))

test('large pass indices stay compact; empty output, unavailable passes and changed private context are explicit', () => fixture(async ({ imported, path, directory, request }) => {
 const job = { kind: 'practice-passes', project: imported.project, asset: imported.asset, sourceRoot: dirname(path), directory }
 const summary = await request(job); assert.deepEqual([summary.lastPass, summary.count], ['2000001', '2000001'])
 const selected = await request({ ...job, kind: 'practice-pass', pass: '2000001' }); assert.equal(selected.full, false)
 assert.equal(selected.cut.extent, '80000'); assert.equal(selected.cut.sourceDivisor, '147')
 for (const pass of ['0', '01', '-1', '2000002']) await assert.rejects(request({ ...job, kind: 'practice-pass', pass }))
 const controller = new AbortController(); controller.abort()
 await assert.rejects(inspectPracticePasses(imported.project, imported.asset, '1', { sourceRoot: dirname(path), directory, signal: controller.signal }), { name: 'AbortError' })
 const context = join(dirname(path), imported.project.assets[0].parts.context.file); await chmod(context, 0o600); await writeFile(context, '{}')
 await assert.rejects(request(job)); assert.deepEqual(await readdir(directory), [])
}, { frames: boundary(2000000n) + 1n, short: true }))

test('no consumed output frames do not invent a practice pass', () => fixture(async ({ imported, path, directory, request }) => {
 const job = { kind: 'practice-passes', project: imported.project, asset: imported.asset, sourceRoot: dirname(path), directory }
 const summary = await request(job); assert.equal(summary.count, '0'); assert.equal(summary.firstPass, null)
 await assert.rejects(request({ ...job, kind: 'practice-pass', pass: '1' }), /outside/)
}, { frames: 0n, short: true }))
