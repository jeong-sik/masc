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
  assert.throws(() => arrangementCommand(editor, `place ${asset.id} 0`), /WAV and UMP together/)
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
