// Execute the actual compiled helper; assert PCM/file decisions, never TUI text.
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdir, writeFile, readFile, readdir } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { createHash } from 'node:crypto'
import { readWaveMetadata } from '../wave-file.mjs'
import { watch } from 'node:fs'
import { exportArrangementWave, renderArrangementWave } from '../arrangement-export.mjs'
import { newArrangement, editArrangement } from '../arrangement.mjs'
import { importArrangementWave } from '../arrangement-files.mjs'
import { arrangementEditor, arrangementImported, arrangementCommand } from '../arrangement-editor.mjs'

const executable = resolve(process.argv[2]), directory = resolve(process.argv[3])
await mkdir(directory)
const hash = bytes => createHash('sha256').update(bytes).digest('hex')
async function asset(id, rate, channels, samples) {
  const bytes = Buffer.alloc(44 + samples.length * 2)
  bytes.write('RIFF'); bytes.writeUInt32LE(bytes.length - 8, 4); bytes.write('WAVEfmt ', 8)
  bytes.writeUInt32LE(16, 16); bytes.writeUInt16LE(1, 20); bytes.writeUInt16LE(channels, 22)
  bytes.writeUInt32LE(rate, 24); bytes.writeUInt32LE(rate * channels * 2, 28)
  bytes.writeUInt16LE(channels * 2, 32); bytes.writeUInt16LE(16, 34)
  bytes.write('data', 36); bytes.writeUInt32LE(samples.length * 2, 40)
  samples.forEach((sample, index) => bytes.writeInt16LE(sample, 44 + index * 2))
  const path = join(directory, `${id}.wav`); await writeFile(path, bytes)
  return { id, path, sha256: hash(bytes), sampleRate: rate, channels, frames: samples.length / channels }
}
const results = []
async function render(name, plan, expected) {
  const file = join(directory, `${name}.json`), output = join(directory, `${name}.wav`)
  await writeFile(file, JSON.stringify(plan))
  const result = spawnSync(executable, ['render', '--file', file, '--output', output], { encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  const receipt = JSON.parse(result.stdout), metadata = await readWaveMetadata(output), bytes = await readFile(output)
  assert.equal(metadata.encoding, 'float'); assert.equal(metadata.bitsPerSample, 32)
  assert.equal(metadata.frames, BigInt(receipt.frames)); assert.equal(metadata.channels, receipt.channels)
  assert.equal(receipt.sampleRate, 44100)
  const sample = (frame, channel = 0) => bytes.readFloatLE(metadata.dataOffset + (frame * metadata.channels + channel) * 4)
  expected({ receipt, sample })
  results.push({ name, receipt, sha256: hash(bytes) })
  return { file, output, bytes }
}
const a = await asset('mono', 44100, 1, [0, 8192, 16384, -8192, -16384, 4096, 0, 0])
const region = (id, start, offset, extent, repeat = 1, asset = a.id) => ({ id, asset,
  startSeconds: start, exportStartFrame: Math.round(start * 44100), offsetFrames: offset, frameCount: extent, repeat })
const plan = (assets, regions, duration) => ({ schemaVersion: 1, kind: 'wave-arrangement', assets, regions, duration })
const overlap = await render('trim-repeat-overlap', plan([a], [region('first', 0, 2, 4, 3), region('second', 3 / 44100, 1, 3)], 12 / 44100), ({ receipt, sample }) => {
  assert.equal(receipt.frames, 12)
  const base = [.5, -.25, -.5, .125]
  for (let frame = 0; frame < 12; frame++) assert.equal(sample(frame), base[frame % 4] + (frame >= 3 && frame < 6 ? [.25, .5, -.25][frame - 3] : 0))
})
await render('silence-placement', plan([a], [region('delayed', 100 / 44100, 2, 4)], 104 / 44100), ({ receipt, sample }) => {
  assert.equal(receipt.frames, 104)
  for (let frame = 0; frame < 100; frame++) assert.equal(sample(frame), 0)
  assert.equal(sample(100), .5); assert.equal(sample(103), .125)
})
const slow = await asset('slow', 22050, 1, Array(22050).fill(8192))
const fast = await asset('fast', 48000, 1, Array(48000).fill(16384))
await render('resampled-overlap', plan([slow, fast], [region('slow', 0, 0, 22050, 1, slow.id), region('fast', .25, 0, 48000, 1, fast.id)], 1.25), ({ receipt, sample }) => {
  assert.equal(receipt.frames, 55125)
  // Sample-rate conversion preserves DC within one source PCM16 LSB.
  assert.ok(Math.abs(sample(4410) - .25) < 1 / 32768)
  assert.ok(Math.abs(sample(22050) - .75) < 1 / 32768)
  assert.ok(Math.abs(sample(48510) - .5) < 1 / 32768)
})
const discrete = await asset('discrete', 44100, 3, Array.from({ length: 30 }, (_, index) => [8192, -16384, 24576][index % 3]))
await render('discrete-channels', plan([discrete], [region('channels', 0, 0, 10, 1, discrete.id)], 10 / 44100), ({ receipt, sample }) => {
  assert.equal(receipt.channels, 3)
  for (let channel = 0; channel < 3; channel++) assert.equal(sample(5, channel), [.25, -.5, .75][channel])
})
const refused = spawnSync(executable, ['render', '--file', overlap.file, '--output', overlap.output], { encoding: 'utf8' })
assert.notEqual(refused.status, 0); assert.deepEqual(await readFile(overlap.output), overlap.bytes)
// Actual immutable document -> verified source snapshot -> native renderer ->
// no-replace public file, including a non-integral tick-to-sample placement.
const imported = await importArrangementWave(newArrangement({ tempo: 120 }), a.path, { projectPath: join(directory, 'project.json') })
let editor = arrangementImported(arrangementEditor(), imported)
editor = arrangementCommand(editor, `region ${imported.asset} 0 2 4 3`).editor
const document = editArrangement(editor.project, { kind: 'region-change', id: editor.project.clips[0].id, position: 1 })
const original = structuredClone(document), published = join(directory, 'published.wav')
const io = { sourceRoot: directory, directory, render: (plan, output, options) => renderArrangementWave(plan, output, { ...options, executable }) }
const publishedReceipt = await exportArrangementWave(document, published, io)
assert.equal(publishedReceipt.frames, 34)
const publishedMetadata = await readWaveMetadata(published), publishedBytes = await readFile(published)
assert.equal(publishedBytes.readFloatLE(publishedMetadata.dataOffset + 22 * 4), .5)
assert.equal(publishedBytes.readFloatLE(publishedMetadata.dataOffset + 33 * 4), .125)
assert.deepEqual(document, original)
await assert.rejects(exportArrangementWave(document, published, io), { code: 'EEXIST' })
assert.deepEqual(await readFile(published), publishedBytes)
const controller = new AbortController(), cancelledPath = join(directory, 'cancelled.wav')
const watcher = watch(directory, { recursive: true }, (event, file) => {
  if (typeof file === 'string' && file.split('/').at(-1).startsWith('.masc-wave-')) controller.abort()
})
try {
  const long = editArrangement(document, { kind: 'region-change', id: document.clips[0].id, repeat: 10_000_000 })
  await assert.rejects(exportArrangementWave(long, cancelledPath, { ...io, signal: controller.signal }), { name: 'AbortError' })
} finally { watcher.close() }
assert.ok(!(await readdir(directory)).includes('cancelled.wav'))
assert.ok((await readdir(directory)).every(name => !name.startsWith('wave-export-') && !name.startsWith('.masc-wave-export-')))
await writeFile(a.path, Buffer.from('changed source'))
const rejectedPath = join(directory, 'rejected.wav')
const rejected = spawnSync(executable, ['render', '--file', overlap.file, '--output', rejectedPath], { encoding: 'utf8' })
assert.notEqual(rejected.status, 0)
assert.ok(!(await readdir(directory)).includes('rejected.wav'))
assert.ok((await readdir(directory)).every(name => !name.startsWith('.masc-wave-')))
await writeFile(join(directory, 'verification.json'), JSON.stringify({ executable, binary_sha256: hash(await readFile(executable)),
  results, published: { receipt: publishedReceipt, sha256: hash(publishedBytes), original_document_preserved: true },
  actual_post_spawn_cancellation: controller.signal.aborted, existing_output_preserved: true, corrupt_source_refused: true, temporary_files_removed: true }, null, 2))
console.log('WAVE_EXPORT_PASS: trim, repetition, overlap, silent placement, source-rate conversion, discrete channels, existing output, corrupt source, cleanup')
