import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, readFile, readdir, rm, chmod } from 'node:fs/promises'
import { join, dirname, sep } from 'node:path'
import { tmpdir } from 'node:os'
import { newArrangement, editArrangement } from '../arrangement.mjs'
import { importArrangementWave } from '../arrangement-files.mjs'
import { importMidiSource } from '../midi-source.mjs'
import { arrangementEditor, arrangementCommand } from '../arrangement-editor.mjs'
import { prepareArrangementMixed, arrangementRoute, selectArrangementRoute, arrangementPlaybackRequest } from '../arrangement-playback.mjs'

async function workspace(run) {
  const root = await mkdtemp(join(tmpdir(), 'masc-mixed-arrangement-'))
  try {
    const wav = Buffer.alloc(44 + 48000 * 2)
    wav.write('RIFF'); wav.writeUInt32LE(wav.length - 8, 4); wav.write('WAVEfmt ', 8); wav.writeUInt32LE(16, 16)
    wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22); wav.writeUInt32LE(48000, 24); wav.writeUInt32LE(96000, 28)
    wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34); wav.write('data', 36); wav.writeUInt32LE(wav.length - 44, 40)
    const path = join(root, 'take.wav'); await writeFile(path, wav)
    let project = (await importArrangementWave(newArrangement({ tempo: 120 }), path, { projectPath: join(root, 'project.json') })).project
    project = editArrangement(project, { kind: 'lane-add', sourceKind: 'wave', name: 'Audio' })
    project = editArrangement(project, { kind: 'region-add', name: 'Region', asset: 'asset-1', lane: 'lane-1', position: 0, offset: 12000, extent: 24000, repeat: 3 })
    const bytes = Buffer.from('4d546864000000060000000101e04d54726b0000000d00903c648360803c4d00ff2f00', 'hex')
    project = editArrangement(project, { kind: 'asset-add', asset: { id: 'm', name: 'Original', kind: 'midi', source: importMidiSource(bytes) } })
    project = editArrangement(project, { kind: 'lane-add', sourceKind: 'midi', name: 'Keys' })
    project = editArrangement(project, { kind: 'region-add', name: 'Region', asset: 'm', lane: 'lane-2', position: 960, offset: 0, extent: 480, repeat: 2 })
    await run({ root, project, wav, bytes })
  } finally { await rm(root, { recursive: true, force: true }) }
}

test('combined preparation retains independent source clocks, compressed repeats, original MIDI bytes and one owned source root', async () => workspace(async ({ root, project, wav, bytes }) => {
  const before = structuredClone(project), files = await readdir(root)
  const result = await prepareArrangementMixed(project, { sourceRoot: root, directory: root, portBindings: [{ asset: 'm', port: 0, destination: '-42' }] })
  const plan = JSON.parse(await readFile(result.path))
  assert.equal(result.format, 'mixed-arrangement'); assert.equal(plan.schemaVersion, 2)
  assert.equal(plan.duration, 1.5); assert.equal(plan.midi.duration, plan.duration)
  assert.deepEqual(plan.regions.map(c => [c.offsetFrames, c.frameCount, c.repeat]), [[12000, 24000, 3]])
  assert.deepEqual(plan.midi.regions.map(c => [c.startSeconds, c.sourceStart, c.sourceEnd, c.repeatCount]), [[.5, 0, .5, 2]])
  assert.deepEqual(plan.midi.sources[0].timeline.events.map(e => e.bytes), [[144, 60, 100], [128, 60, 77]])
  assert.deepEqual(await readFile(plan.assets[0].path), wav)
  assert.ok(plan.assets[0].path.startsWith(dirname(result.path) + sep))
  assert.equal((await readdir(root)).filter(f => !files.includes(f)).length, 1)
  assert.deepEqual(result.bindings, [{ port: 0, destination: '-42' }])
  assert.deepEqual(project, before)
  assert.deepEqual(Buffer.from(project.assets.find(a => a.id === 'm').source.original, 'base64'), bytes)
}))

test('combined preparation failure or cancellation removes both subplans and never publishes a partial plan', async () => workspace(async ({ root, project }) => {
  const before = await readdir(root)
  await assert.rejects(prepareArrangementMixed(project, { sourceRoot: root, directory: root }), /output for every/)
  assert.deepEqual(await readdir(root), before)
  const wav = join(root, project.assets[0].file)
  await chmod(wav, 0o600); const changed = await readFile(wav); changed[44] = 1; await writeFile(wav, changed)
  await assert.rejects(prepareArrangementMixed(project, { sourceRoot: root, directory: root, midiOutput: '-42' }), /changed/)
  assert.deepEqual(await readdir(root), before)
  const controller = new AbortController(); controller.abort()
  await assert.rejects(prepareArrangementMixed(project, { sourceRoot: root, directory: root, midiOutput: '-42', signal: controller.signal }), { name: 'AbortError' })
  assert.deepEqual(await readdir(root), before)
}))

test('explicit mixed routing preserves each output intent while audible mute/solo selects the required native plan', async () => workspace(async ({ project }) => {
  let route = arrangementRoute({ midiOutput: '-42' })
  assert.throws(() => arrangementPlaybackRequest(project, route), /mixed-output/)
  const effect = arrangementCommand(arrangementEditor(project), 'mixed-output Audio device UID').effect
  route = selectArrangementRoute(route, effect)
  assert.deepEqual(arrangementPlaybackRequest(project, route), { kind: 'prepare-mixed', output: 'Audio device UID', midiOutput: '-42', portBindings: [] })
  route = selectArrangementRoute(route, { kind: 'midi-port', asset: 'm', port: 0, destination: '43' })
  assert.equal(route.kind, 'mixed'); assert.equal(route.output, 'Audio device UID')
  assert.deepEqual(route.portBindings, [{ asset: 'm', port: 0, destination: '43' }])
  const mutedMidi = editArrangement(project, { kind: 'lane-mute', id: 'lane-2' })
  assert.deepEqual(arrangementPlaybackRequest(mutedMidi, route), { kind: 'prepare-wave', output: 'Audio device UID' })
  const mutedAudio = editArrangement(project, { kind: 'lane-mute', id: 'lane-1' })
  assert.equal(arrangementPlaybackRequest(mutedAudio, route).kind, 'prepare-midi')
  route = selectArrangementRoute(route, { kind: 'output', path: 'Audio only' })
  assert.deepEqual(route, { kind: 'audio', output: 'Audio only' })
  assert.throws(() => arrangementPlaybackRequest(mutedAudio, route), /MIDI destination/)
  assert.equal(arrangementRoute({ output: 'Audio', midiOutput: '-42' }).kind, 'mixed')
}))
