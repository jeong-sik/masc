// Actual offline synth + arrangement helper, with no audio/MIDI device opened.
import assert from 'node:assert/strict'
import { mkdir, writeFile, readFile, readdir } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { createHash } from 'node:crypto'
import { newArrangement, editArrangement } from '../arrangement.mjs'
import { importArrangementWave } from '../arrangement-files.mjs'
import { midiSourceFromEvents } from '../midi-source.mjs'
import { captureFluidSound } from '../soundfont.mjs'
import { exportArrangementWave, renderArrangementWave } from '../arrangement-export.mjs'
import { readWaveMetadata } from '../wave-file.mjs'

const executable = resolve(process.argv[2]), directory = resolve(process.argv[3])
await mkdir(directory)
const hash = bytes => createHash('sha256').update(bytes).digest('hex')
const sound = await captureFluidSound().promise
const source = midiSourceFromEvents([
  { tick: 0, kind: 'channel', bytes: [0x90, 60, 100] },
  { tick: 960, kind: 'channel', bytes: [0x80, 60, 0] },
  { tick: 1920, kind: 'meta', type: 47, data: [] },
], { ppq: 960, sound })
let project = editArrangement(newArrangement({ tempo: 120 }), { kind: 'lane-add', sourceKind: 'midi', name: 'Keys' })
project = editArrangement(project, { kind: 'asset-add', asset: { id: 'font', name: 'Bound', kind: 'midi', source } })
project = editArrangement(project, { kind: 'region-add', name: 'Exact repeated cut', asset: 'font', lane: 'lane-1',
  position: 1, offset: 1, extent: 478, repeat: 3 })
const bytes = Buffer.alloc(44 + 10 * 2)
bytes.write('RIFF'); bytes.writeUInt32LE(bytes.length - 8, 4); bytes.write('WAVEfmt ', 8); bytes.writeUInt32LE(16, 16)
bytes.writeUInt16LE(1, 20); bytes.writeUInt16LE(1, 22); bytes.writeUInt32LE(44100, 24); bytes.writeUInt32LE(88200, 28)
bytes.writeUInt16LE(2, 32); bytes.writeUInt16LE(16, 34); bytes.write('data', 36); bytes.writeUInt32LE(20, 40)
for (let frame = 0; frame < 10; frame++) bytes.writeInt16LE(8192, 44 + frame * 2)
const originalWave = join(directory, 'original.wav'); await writeFile(originalWave, bytes)
const imported = await importArrangementWave(project, originalWave, { projectPath: join(directory, 'song.json') })
project = editArrangement(imported.project, { kind: 'lane-add', sourceKind: 'wave', name: 'Recorded' })
project = editArrangement(project, { kind: 'region-add', name: 'WAV prefix', asset: imported.asset, lane: 'lane-2',
  position: 0, offset: 0, extent: 10, repeat: 1 })
project = { ...project, playbackLoop: { start: 240, end: 960 }, practice: { countInBars: 1, metronome: true } }
const before = structuredClone(project), plans = [], progress = []
const io = { sourceRoot: directory, directory, onProgress: event => progress.push(event),
  render: async (path, output, options) => {
    const plan = JSON.parse(await readFile(path))
    assert.equal(plan.assets.filter(asset => asset.realization?.kind === 'soundfont').length, 1)
    assert.equal(plan.regions.find(region => region.sourceClock).exportStartFrame, 22)
    plans.push(plan)
    return renderArrangementWave(path, output, { ...options, executable })
  } }
const target = join(directory, 'mixed.wav'), receipt = await exportArrangementWave(project, target, io)
assert.equal(receipt.frames, 32960); assert.equal(receipt.channels, 2)
const metadata = await readWaveMetadata(target), output = await readFile(target)
assert.equal(metadata.encoding, 'float'); assert.equal(metadata.bitsPerSample, 32)
const sample = (frame, channel) => output.readFloatLE(metadata.dataOffset + (frame * 2 + channel) * 4)
for (let frame = 0; frame < 22; frame++) for (let channel = 0; channel < 2; channel++) {
  assert.equal(sample(frame, channel), frame < 10 ? .25 : 0)
}
let audible = false
for (let frame = 22; frame < receipt.frames; frame++) for (let channel = 0; channel < 2; channel++) {
  const value = sample(frame, channel); assert.ok(Number.isFinite(value)); audible ||= value !== 0
}
assert.ok(audible); assert.deepEqual(project, before); assert.deepEqual(await readFile(originalWave), bytes)
await assert.rejects(exportArrangementWave(project, target, io), { code: 'EEXIST' })
assert.deepEqual(await readFile(target), output)
assert.ok((await readdir(directory)).every(name => !name.startsWith('wave-export-') && !name.startsWith('.masc-wave-export-')))
await writeFile(join(directory, 'verification.json'), JSON.stringify({ executable, binarySha256: hash(await readFile(executable)),
  receipt, outputSha256: hash(output), sound: { fontSha256: sound.font.sha256, engine: sound.engine, bankStyle: sound.bankStyle },
  sourceHash: hash(Buffer.from(JSON.stringify(source))), originalPreserved: true, existingOutputPreserved: true,
  exactPlacementFrame: 22, rationalRepeatEndFrame: 32960, wavPrefixAndSilenceVerified: true, audibleFiniteSynthSamples: true,
  plans, progress, limits: ['Offline PCM/file proof; no physical sound, TUI keys, vendor VST or installed runtime proof'] }, null, 2))
console.log('SOUNDFONT_WAVE_EXPORT_PASS: actual synth/mixer, rational trim/repeats, WAV mix, silent placement, immutable source, no-overwrite, cleanup')
