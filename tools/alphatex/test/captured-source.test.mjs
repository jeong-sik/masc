import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, readFile, readdir, stat, chmod, rm } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { tmpdir } from 'node:os'
import JZZ from 'jzz'
import { newArrangement } from '../arrangement.mjs'
import { capturePartNames } from '../captured-source.mjs'
import { importArrangementCapture, saveArrangement, loadArrangement, prepareArrangementCapture, verifyArrangementAssets } from '../arrangement-files.mjs'
import { readCapture } from '../session-data.mjs'
import { arrangementEditor, arrangementCommand } from '../arrangement-editor.mjs'
import { captureRange, captureRegionTime, captureRegionFromSeconds } from '../capture-time.mjs'
import { arrangementSchedule, editArrangement } from '../arrangement.mjs'
import { arrangementPlaybackRequest, prepareArrangementWave, prepareArrangementMidi, prepareArrangementMixed } from '../arrangement-playback.mjs'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { loadProject } from '../sequencer-files.mjs'
import { createHash } from 'node:crypto'

async function fixture(run) {
  const root = await mkdtemp(join(tmpdir(), 'masc-captured-source-')), input = join(root, 'Original take')
  try {
    const { mkdir } = await import('node:fs/promises'); await mkdir(input)
    const origin = 9007199254740993123n, at = seconds => String(origin + BigInt(Math.round(seconds * 24000000)))
    const manifest = { schemaVersion: 1, state: 'recorded', failure: null, audio: 'audio.wav', audioBlocks: 'audio-blocks.jsonl', midi: 'midi.ump.jsonl',
      sampleRate: 48000, channels: 1, audioFrames: '4800', midiPacketCount: '3',
      clock: { kind: 'mach-host-time', numer: 125, denom: 3, requestedStart: String(origin), firstAudioHostTime: at(.1) },
      input: { id: 'audio', name: 'Interface' }, midiSources: [{ id: 'A', name: 'Keys' }, { id: 'B', name: 'Pads' }] }
    const wave = Buffer.alloc(44 + 4800 * 2)
    wave.write('RIFF'); wave.writeUInt32LE(wave.length - 8, 4); wave.write('WAVEfmt ', 8); wave.writeUInt32LE(16, 16)
    wave.writeUInt16LE(1, 20); wave.writeUInt16LE(1, 22); wave.writeUInt32LE(48000, 24); wave.writeUInt32LE(96000, 28)
    wave.writeUInt16LE(2, 32); wave.writeUInt16LE(16, 34); wave.write('data', 36); wave.writeUInt32LE(wave.length - 44, 40)
    const packet = (seconds, source, timestampOrigin, messages) => {
      const bytes = Buffer.from(messages.flatMap(message => [...message]))
      return { kind: 'midi', protocol: 2, hostTime: at(seconds), source, timestampOrigin,
        words: Array.from({ length: bytes.length / 4 }, (_, i) => bytes.readUInt32BE(i * 4)) }
    }
    const rows = [packet(.05, 'A', 'packet', [JZZ.UMP.umpNoteOn(3, 5, 60, 0x9001), JZZ.UMP.umpPitchBend(3, 5, 0x87654321), JZZ.UMP.umpControl(3, 5, 74, 0xabcdef01)]),
      packet(.07, 'B', 'received', [JZZ.UMP.umpNoteOn(1, 2, 36, 0xffff)]), packet(.15, 'A', 'packet', [JZZ.UMP.umpNoteOff(3, 5, 60, 0x1234)])]
    const bytes = { manifest: Buffer.from(JSON.stringify(manifest, null, 2) + '\n'), audio: wave,
      audioBlocks: Buffer.from(JSON.stringify({ kind: 'audio', hostTime: at(.1), deviceSampleTime: '-12', frameOffset: '0', frameCount: 4800, peaks: [[-.2, .3]] }) + '\n'),
      midi: Buffer.from(rows.map(row => JSON.stringify(row)).join('\n') + '\n') }
    for (const [role, filename] of Object.entries(capturePartNames)) await writeFile(join(input, filename), bytes[role])
    await run({ root, input, bytes, manifest })
  } finally { await rm(root, { recursive: true, force: true }) }
}

test('a project owns the whole captured source and survives original removal and save-as with exact UMP/clock provenance', async () => fixture(async ({ root, input, bytes, manifest }) => {
  const path = join(root, 'project', 'song.json'), imported = await importArrangementCapture(newArrangement(), input, { projectPath: path })
  const asset = imported.project.assets[0]
  assert.equal(asset.kind, 'capture'); assert.deepEqual(asset.manifest, manifest)
  for (const [role, part] of Object.entries(asset.parts)) {
    const file = join(dirname(path), part.file)
    assert.deepEqual(await readFile(file), bytes[role]); assert.notEqual((await stat(file)).ino, (await stat(join(input, capturePartNames[role]))).ino)
    assert.equal((await stat(file)).mode & 0o222, 0)
  }
  await saveArrangement(path, imported.project); await rm(input, { recursive: true })
  const loaded = await loadArrangement(path); assert.deepEqual(loaded.project, imported.project)
  const next = join(root, 'copy', 'moved.json'); await saveArrangement(next, loaded.project, null, { sourceRoot: dirname(path) })
  await rm(dirname(path), { recursive: true }); const moved = await loadArrangement(next)
  const snapshot = await prepareArrangementCapture(moved.project, asset.id, { sourceRoot: dirname(next), directory: root })
  const timeline = await readCapture(snapshot.directory)
  assert.equal(timeline.audio[0].hostTime, manifest.clock.firstAudioHostTime); assert.equal(timeline.audio[0].time, .1)
  const tracks = [...timeline.midi.values()]
  assert.deepEqual([tracks[0].source, tracks[0].group, tracks[0].channel, tracks[0].notes[0].start, tracks[0].notes[0].end], ['A', 3, 5, .05, .15])
  assert.deepEqual(tracks[0].events[0].message.slice(0), [...JZZ.UMP.umpNoteOn(3, 5, 60, 0x9001)])
  assert.equal(tracks[1].events[0].timestampOrigin, 'received'); assert.equal(tracks[1].notes[0].end, null)
  for (const [role, filename] of Object.entries(capturePartNames)) assert.deepEqual(await readFile(join(snapshot.directory, filename)), bytes[role])
  const editor = arrangementEditor(moved.project)
  assert.deepEqual(arrangementCommand(editor, 'open-take').effect, { kind: 'open-take', asset: asset.id })
  const placed = arrangementCommand(editor, `place ${asset.id} 0`).editor
  assert.equal(placed.project.lanes[0].kind, 'capture')
  assert.equal(placed.project.clips[0].offset, '0'); assert.equal(placed.project.clips[0].extent, '4800000')
  assert.deepEqual(asset.midiTime, { first: String(BigInt(manifest.clock.requestedStart) + 1200000n), last: String(BigInt(manifest.clock.requestedStart) + 3600000n) })
}))

test('view snapshots keep their owned bytes while a changed project part fails admission', async () => fixture(async ({ root, input, bytes }) => {
  const path = join(root, 'project', 'song.json'), { project } = await importArrangementCapture(newArrangement(), input, { projectPath: path })
  const snapshot = await prepareArrangementCapture(project, project.assets[0].id, { sourceRoot: dirname(path), directory: root })
  const changed = join(dirname(path), project.assets[0].parts.midi.file); await chmod(changed, 0o600); await writeFile(changed, '{}\n')
  assert.deepEqual(await readFile(join(snapshot.directory, 'midi.ump.jsonl')), bytes.midi)
  await assert.rejects(verifyArrangementAssets(project, dirname(path)), /content changed/)
  await assert.rejects(prepareArrangementCapture(project, project.assets[0].id, { sourceRoot: dirname(path), directory: root }), /content changed/)
}))

test('manifest/data mismatches refuse attachment and abort leaves no private import or viewer root', async () => fixture(async ({ root, input, manifest }) => {
  const path = join(root, 'project', 'song.json'), original = newArrangement()
  const bad = { ...manifest, clock: { ...manifest.clock, firstAudioHostTime: manifest.clock.requestedStart } }
  await writeFile(join(input, 'session.json'), JSON.stringify(bad))
  await assert.rejects(importArrangementCapture(original, input, { projectPath: path }), /clock provenance/)
  assert.equal(original.assets.length, 0)
  assert.ok((await readdir(join(dirname(path), 'assets'))).every(file => !file.startsWith('.import-')))
  const controller = new AbortController(); controller.abort()
  await assert.rejects(importArrangementCapture(original, input, { projectPath: path, signal: controller.signal }), { name: 'AbortError' })
  await writeFile(join(input, 'session.json'), JSON.stringify(manifest))
  const { project } = await importArrangementCapture(original, input, { projectPath: path })
  const before = await readdir(root)
  await assert.rejects(prepareArrangementCapture(project, project.assets[0].id, { sourceRoot: dirname(path), directory: root, signal: controller.signal }), { name: 'AbortError' })
  assert.deepEqual(await readdir(root), before)
}))

test('captured regions retain exact source clocks through time trims, compressed repeats, undo, save-as and worker reopen', async () => fixture(async ({ root, input, bytes }) => {
  const worker = new Worker(new URL('../arrangement-worker.mjs', import.meta.url))
  let id = 0
  const request = async value => {
    const response = once(worker, 'message'); worker.postMessage({ ...value, id: ++id })
    const [message] = await response; assert.equal(message.ok, true, message.error); return message.result
  }
  try {
    const path = join(root, 'old', 'song.json'), imported = await request({ kind: 'import-take', project: newArrangement({ tempo: 120 }), path: input, projectPath: path })
    let editor = arrangementEditor(imported.project)
    const command = line => { editor = arrangementCommand(editor, line).editor }
    command('capture-region asset-1 4 .05 .1 2000000')
    const placed = editor.project
    assert.deepEqual(placed.clips.map(clip => [clip.offset, clip.extent, clip.repeat]), [['1200000','2400000',2000000]])
    const schedule = arrangementSchedule(placed)
    assert.equal(schedule.length, 1); assert.equal(schedule[0].startSeconds, 2); assert.equal(schedule[0].durationSeconds, .1)
    assert.deepEqual(schedule[0].audio, { offsetFrames: '0', frameCount: '2400', startSeconds: .05 })
    command('trim-time .1 .1'); command('duplicate 8'); command('move 12'); command('undo'); command('redo')
    assert.equal(editor.project.clips[1].position, 12 * 960)
    assert.deepEqual(editor.project.clips.map(clip => [clip.offset, clip.extent]), [['2400000','2400000'],['2400000','2400000']])
    const muted = editArrangement(editor.project, { kind: 'lane-mute', id: 'lane-1' }); assert.deepEqual(arrangementSchedule(muted), [])
    assert.equal(arrangementSchedule(muted, { all: true }).length, 2)
    const before = editor
    for (const line of ['trim 01 2','trim -1 2','trim-time .1 0','trim-time .15 .1','repeat 0','region asset-1 0 0 4800001','place asset-1 0 1']) assert.throws(() => arrangementCommand(editor, line))
    assert.equal(editor, before)
    // Undo the whole import in another history state. Save-as must carry the
    // retained source, then a redo can restore its clock-aware regions.
    const target = join(root, 'moved', 'song.json')
    const revision = await request({ kind: 'save', project: newArrangement(), path: target, revision: null,
      sourceRoot: dirname(path), retainedAssets: imported.project.assets })
    await rm(input, { recursive: true }); await rm(dirname(path), { recursive: true })
    await request({ kind: 'save', project: editor.project, path: target, revision, sourceRoot: dirname(target) })
    const moved = await loadArrangement(target)
    assert.deepEqual(moved.project, editor.project); assert.equal(arrangementSchedule(moved.project).length, 2)
    for (const [role, part] of Object.entries(moved.project.assets[0].parts)) assert.deepEqual(await readFile(join(dirname(target), part.file)), bytes[role])
  } finally { await worker.terminate() }
}))

test('half-open capture spans preserve MIDI pre-roll and endpoint packets, with inward whole-frame audio trims', async () => fixture(async ({ root, input }) => {
  const imported = await importArrangementCapture(newArrangement(), input, { projectPath: join(root, 'project', 'song.json') })
  const asset = imported.project.assets[0], origin = BigInt(asset.manifest.clock.requestedStart)
  const withTail = { ...asset, midiTime: { first: String(origin - 1n), last: String(origin + 4800000n) } }
  assert.deepEqual(captureRange(withTail), { origin: String(origin - 1n), extent: '4800002' })
  const full = captureRegionTime(withTail, { offset: '0', extent: '4800002' })
  assert.deepEqual(full.audio, { offsetFrames: '0', frameCount: '4800', startSeconds: 2400001 / 24000000 })
  const inward = captureRegionTime(asset, { offset: '2400001', extent: '1000' })
  assert.deepEqual(inward.audio, { offsetFrames: '1', frameCount: '1', startSeconds: 499 / 24000000 })
  assert.equal(captureRegionTime(asset, { offset: '2400001', extent: '498' }).audio, null)
  assert.equal(captureRegionTime(asset, { offset: '0', extent: '2400000' }).audio, null)
  const fractional = { ...asset, manifest: { ...asset.manifest, audioFrames: '1', sampleRate: 44100,
    midiPacketCount: '0', clock: { ...asset.manifest.clock, firstAudioHostTime: String(origin) } }, midiTime: { first: null, last: null } }
  assert.equal(captureRange(fractional).extent, '545')
  assert.deepEqual(captureRegionTime(fractional, { offset: '0', extent: '545' }).audio, { offsetFrames: '0', frameCount: '1', startSeconds: 0 })
  assert.equal(captureRegionTime(fractional, { offset: '0', extent: '544' }).audio, null)
  assert.deepEqual(captureRegionFromSeconds(asset, '0.0000000416666666666666666667', '.000001'), { offset: '2', extent: '23' })
}))

test('capture timing provenance is verified against raw source packets on reopen and snapshot preparation', async () => fixture(async ({ root, input }) => {
  const path = join(root, 'project', 'song.json'), { project } = await importArrangementCapture(newArrangement(), input, { projectPath: path })
  const wrong = structuredClone(project); wrong.assets[0].midiTime.last = wrong.assets[0].midiTime.first
  await assert.rejects(saveArrangement(path, wrong), /clock provenance/)
  await assert.rejects(prepareArrangementCapture(wrong, 'asset-1', { sourceRoot: dirname(path), directory: root }), /clock provenance/)
  const invalid = structuredClone(project); invalid.assets[0].midiTime.first = '-1'
  assert.throws(() => arrangementEditor(invalid), /first MIDI time/)
}))

for (const midi of [true, false]) test(`legacy schema-1 ${midi ? 'MIDI' : 'WAV-only'} captures reopen with verified timing and retain their original revision`, async () => fixture(async ({ root, input, manifest }) => {
  if (!midi) {
    await writeFile(join(input, 'session.json'), JSON.stringify({ ...manifest, midiPacketCount: '0', midiSources: [] }))
    await writeFile(join(input, 'midi.ump.jsonl'), '')
  }
  const path = join(root, 'project', 'song.json')
  const { project } = await importArrangementCapture(newArrangement(), input, { projectPath: path })
  const legacy = structuredClone(project); delete legacy.assets[0].midiTime
  const original = JSON.stringify(legacy, null, 2) + '\n'
  await writeFile(path, original)
  await rm(input, { recursive: true })
  const loaded = await loadArrangement(path), routed = await loadProject(path)
  assert.deepEqual(loaded.project, project); assert.deepEqual(routed, loaded)
  assert.equal(loaded.revision, createHash('sha256').update(original).digest('hex'))
  assert.equal(await readFile(path, 'utf8'), original)
  const copy = join(root, 'copy', 'song.json')
  await saveArrangement(copy, loaded.project, null, { sourceRoot: dirname(path) })
  assert.deepEqual((await loadArrangement(copy)).project, project)
  await saveArrangement(path, loaded.project, loaded.revision)
  assert.deepEqual(JSON.parse(await readFile(path, 'utf8')), project)
}))

test('legacy capture upgrade rejects changed bytes, forged provenance, unsafe paths and present invalid timing', async () => fixture(async ({ root, input }) => {
  const path = join(root, 'project', 'song.json')
  const { project } = await importArrangementCapture(newArrangement(), input, { projectPath: path })
  const legacy = structuredClone(project); delete legacy.assets[0].midiTime
  const forged = structuredClone(legacy); forged.assets[0].manifest.input.name = 'Forged input'
  await writeFile(path, JSON.stringify(forged))
  await assert.rejects(loadArrangement(path), /clock provenance/)
  const unsafe = structuredClone(legacy); unsafe.assets[0].parts.midi.file = '../outside.capture'
  await writeFile(path, JSON.stringify(unsafe))
  await assert.rejects(loadProject(path), /identity\/path/)
  const invalid = structuredClone(legacy); invalid.assets[0].midiTime = null
  await writeFile(path, JSON.stringify(invalid))
  await assert.rejects(loadProject(path), /MIDI time bounds/)
  await writeFile(path, JSON.stringify(legacy))
  const controller = new AbortController(); controller.abort()
  await assert.rejects(loadArrangement(path, { signal: controller.signal }), { name: 'AbortError' })
  const changed = join(dirname(path), legacy.assets[0].parts.midi.file)
  await chmod(changed, 0o600); await writeFile(changed, '{}\n')
  await assert.rejects(loadArrangement(path), /content changed/)
}))

test('every arrangement playback entrypoint diagnoses audible capture regions instead of silently filtering them', async () => fixture(async ({ root, input }) => {
  const path = join(root, 'project', 'song.json'), { project } = await importArrangementCapture(newArrangement(), input, { projectPath: path })
  const placed = arrangementCommand(arrangementEditor(project), 'place asset-1 0').editor.project
  for (const kind of ['audio','midi','mixed']) assert.throws(() => arrangementPlaybackRequest(placed, { kind }), /Captured-region playback/)
  const options = { sourceRoot: dirname(path), directory: root, midiOutput: '42' }
  for (const prepare of [prepareArrangementWave, prepareArrangementMidi, prepareArrangementMixed]) await assert.rejects(prepare(placed, options), /Captured-region playback/)
  const muted = editArrangement(placed, { kind: 'lane-mute', id: 'lane-1' })
  assert.throws(() => arrangementPlaybackRequest(muted, { kind: 'mixed' }), /No audible/)
  const worker = new Worker(new URL('../arrangement-worker.mjs', import.meta.url))
  try {
    for (const [id, kind] of ['prepare-wave','prepare-midi','prepare-mixed'].entries()) {
      const response = once(worker, 'message'); worker.postMessage({ id, kind, project: placed, ...options })
      const [message] = await response; assert.equal(message.ok, false); assert.match(message.error, /Captured-region playback/)
    }
  } finally { await worker.terminate() }
}))
