import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, writeFile, readdir, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { newArrangement, editArrangement } from '../arrangement.mjs'
import { arrangementEditor, arrangementImported, arrangementCommand } from '../arrangement-editor.mjs'
import { arrangementWaveProject, exportArrangementWave } from '../arrangement-export.mjs'
import { attachRecordedTake } from '../arrangement-recording.mjs'

const asset = { id: 'wave', name: 'Recorded', kind: 'wave', file: `assets/${'a'.repeat(64)}.wav`, sha256: 'a'.repeat(64),
  metadata: { encoding: 'pcm', channels: 1, sampleRate: 44100, bitsPerSample: 16, validBits: 16, blockAlign: 2, frames: 4 } }
function project() {
  let editor = arrangementImported(arrangementEditor(), { project: editArrangement(newArrangement({ tempo: 120 }), { kind: 'asset-add', asset }), asset: asset.id })
  editor = arrangementCommand(editor, 'place wave 1').editor
  editor = arrangementCommand(editor, 'repeat 3').editor
  return editor.project
}
function floatWave() {
  const bytes = Buffer.alloc(60)
  bytes.write('RIFF'); bytes.writeUInt32LE(52, 4); bytes.write('WAVEfmt ', 8); bytes.writeUInt32LE(16, 16)
  bytes.writeUInt16LE(3, 20); bytes.writeUInt16LE(1, 22); bytes.writeUInt32LE(44100, 24); bytes.writeUInt32LE(176400, 28)
  bytes.writeUInt16LE(4, 32); bytes.writeUInt16LE(32, 34); bytes.write('data', 36); bytes.writeUInt32LE(16, 40)
  return bytes
}
function boundary(root, { duringRender } = {}) {
  const observed = []
  return { observed,
    async prepareAudio(project, options) {
      observed.push(structuredClone(project))
      const path = join(options.directory, 'plan.json')
      await writeFile(path, JSON.stringify({ duration: 1, assets: [], regions: [{ id: project.clips[0].id }] }))
      return { path }
    },
    async render(plan, path, { signal }) {
      observed.push(JSON.parse(await readFile(plan, 'utf8')))
      await duringRender?.(signal)
      signal?.throwIfAborted()
      await writeFile(path, floatWave())
      return { kind: 'rendered', path, frames: 4, sampleRate: 44100, channels: 1, peak: 0 }
    }, directory: root, sourceRoot: root }
}

test('export freezes the complete document and exact placement independently of practice and playback loop', async () => {
  const original = project(), selected = editArrangement(editArrangement(original, { kind: 'loop', range: { start: 960, end: 1920 } }),
    { kind: 'practice', practice: { countInBars: 1, metronome: true } })
  const before = structuredClone(selected), linear = arrangementWaveProject(selected)
  assert.deepEqual(selected.playbackLoop, { start: 960, end: 1920 })
  assert.equal(linear.playbackLoop, undefined); assert.equal(linear.practice, undefined)
  assert.deepEqual(linear.clips, selected.clips); assert.deepEqual(selected, before)
  const root = await mkdtemp(join(tmpdir(), 'masc-export-snapshot-'))
  try {
    const io = boundary(root), target = join(root, 'mix.wav')
    await exportArrangementWave(selected, target, io)
    assert.equal(io.observed[0].playbackLoop, undefined)
    assert.equal(io.observed[0].practice, undefined)
    assert.equal(io.observed[1].regions[0].exportStartFrame, 22050)
    assert.deepEqual(selected, before)
    assert.deepEqual(await readFile(target), floatWave())
    assert.deepEqual(await readdir(root), ['mix.wav'])
  } finally { await rm(root, { recursive: true, force: true }) }
})

test('existing destination and cancelled export preserve user files and remove all owned preparation trees', async () => {
  const root = await mkdtemp(join(tmpdir(), 'masc-export-publication-'))
  try {
    const target = join(root, 'mix.wav'), old = Buffer.from('existing user output')
    await writeFile(target, old)
    await assert.rejects(exportArrangementWave(project(), target, boundary(root)), { code: 'EEXIST' })
    assert.deepEqual(await readFile(target), old)
    const controller = new AbortController()
    await assert.rejects(exportArrangementWave(project(), join(root, 'cancelled.wav'), {
      ...boundary(root, { duringRender() { controller.abort() } }), signal: controller.signal }), { name: 'AbortError' })
    assert.deepEqual(await readdir(root), ['mix.wav'])
  } finally { await rm(root, { recursive: true, force: true }) }
})

test('captured MIDI is refused until its audio component is explicitly selected; original capture remains intact', () => {
  const origin = 9007199254740993123n
  const source = { kind: 'capture', id: 'take', name: 'Input',
    parts: Object.fromEntries(['manifest', 'audio', 'audioBlocks', 'midi'].map(role => [role, { sha256: 'a'.repeat(64), file: `assets/${'a'.repeat(64)}.${role === 'audio' ? 'wav' : 'capture'}` }])),
    manifest: { schemaVersion: 1, state: 'recorded', failure: null, audio: 'audio.wav', audioBlocks: 'audio-blocks.jsonl', midi: 'midi.ump.jsonl',
      clock: { kind: 'mach-host-time', numer: 125, denom: 3, requestedStart: String(origin), firstAudioHostTime: String(origin) },
      sampleRate: 48000, channels: 1, audioFrames: '48000', midiPacketCount: '2',
      input: { id: 'input', name: 'Interface' }, midiSources: [{ id: 'source', name: 'Keys' }] },
    midiTime: { first: String(origin), last: String(origin + 12000000n) } }
  const base = newArrangement(), paired = attachRecordedTake(base, { project: { ...base, assets: [source] }, asset: source.id },
    { duration: 20, clock: { kind: 'mach-host-time', anchor: String(origin), position: 0, numer: 125, denom: 3 } }).project
  const before = structuredClone(paired)
  assert.throws(() => arrangementWaveProject(paired), /Captured MIDI/)
  const split = editArrangement(paired, { kind: 'capture-split', id: paired.clips[0].id })
  const midi = split.clips.find(clip => clip.component === 'midi')
  const audio = editArrangement(split, { kind: 'lane-mute', id: midi.lane })
  assert.ok(arrangementWaveProject(audio))
  assert.deepEqual(paired, before)
})
