import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, readFile, rm, readdir } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { createHash } from 'node:crypto'
import { captureFluidSound, fluidRenderPlan, renderFluidSound } from '../soundfont.mjs'
import { importMidiSource, midiSourceFromEvents } from '../midi-source.mjs'
import { validateSound } from '../project-sound.mjs'
import { readWaveMetadata } from '../wave-file.mjs'
import { newEditor, editorCommand } from '../sequencer-editor.mjs'
import { saveProject, loadProject } from '../sequencer-files.mjs'

const channel = (tick, bytes) => ({ tick, kind: 'channel', bytes })
const meta = (tick, type, data) => ({ tick, kind: 'meta', type, data })
const digest = bytes => createHash('sha256').update(bytes).digest('hex')
function source(sustain = 127) {
  return midiSourceFromEvents([meta(0, 0x51, [7, 161, 32]), channel(0, [0xc0, 0]),
    channel(0, [0xb0, 64, sustain]), channel(0, [0x90, 60, 100]),
    channel(480, [0x80, 60, 0]), channel(1440, [0xb0, 64, 0]), meta(3840, 0x2f, [])], { ppq: 960 })
}
async function fixture(action) {
  const root = await mkdtemp(join(tmpdir(), 'masc-fluid-test-'))
  const sound = await captureFluidSound().promise
  const render = async (project, name, changed = {}) => {
    const plan = { ...fluidRenderPlan(project), ...changed }, path = join(root, name + '.json')
    const bytes = Buffer.from(JSON.stringify(plan))
    await writeFile(path, bytes)
    return renderFluidSound(sound, { preparation: { promise: Promise.resolve({ path, sha256: digest(bytes) }), cancel: new Int32Array(new SharedArrayBuffer(4)) }, outputPath: join(root, name + '.wav') })
  }
  try { await action({ root, sound, render }) } finally { await rm(root, { recursive: true, force: true }) }
}
async function samples(path) {
  const metadata = await readWaveMetadata(path), bytes = await readFile(path), values = []
  for (let i = metadata.dataOffset; i < metadata.dataOffset + metadata.dataBytes; i += 4) values.push(bytes.readFloatLE(i))
  assert.ok(values.every(Number.isFinite))
  return { metadata, values }
}

test('actual FluidSynth preserves sustain, exact source horizon, frozen SF2 and portable save/reopen', () => fixture(async ({ root, sound, render }) => {
  const input = source(), original = structuredClone(input)
  const a = await (await render(input, 'pedal')).promise
  const b = await (await render(source(0), 'dry')).promise
  assert.equal(a.soundfont.fontSha256, sound.font.sha256)
  assert.equal(a.soundfont.engine.version, sound.engine.version)
  assert.equal(a.soundfont.frames, 88200)
  const wet = await samples(a.path), dry = await samples(b.path)
  assert.equal(wet.metadata.frames, 88200n); assert.equal(wet.metadata.encoding, 'float')
  const energy = values => values.slice(15435 * 2, 28665 * 2).reduce((n, x) => n + x * x, 0)
  assert.ok(energy(wet.values) > energy(dry.values))
  assert.deepEqual(input, original)
  const bound = { ...input, sound }, target = join(root, 'source.json')
  await saveProject(target, bound, null)
  assert.deepEqual((await loadProject(target)).project, bound)
  const tampered = structuredClone(sound); tampered.font.data = Buffer.from('different').toString('base64')
  assert.throws(() => validateSound(tampered), /SF2/)
  assert.deepEqual(editorCommand(newEditor(bound), 'soundfont-fluid /font with spaces.sf2').effect,
    { kind: 'soundfont-fluid', path: '/font with spaces.sf2' })
}))

test('actual independent source ports retain the audible voice when another port mutes the same channel', () => fixture(async ({ render }) => {
  const plan = fluidRenderPlan(source()), port = plan.ports[0]
  const quiet = { port: 1, events: port.events.map(event => ({ ...event, bytes: [...event.bytes] })) }
  quiet.events.splice(0, 0, { frame: 0, bytes: [0xb0, 7, 0] })
  // The first port's program, pedal and notes cannot overwrite another port's
  // silent CC7 state even though both use channel zero and the same pitch.
  const silent = await (await render(source(), 'silent', { ports: [quiet] })).promise
  const separate = await (await render(source(), 'separate', { ports: [port, quiet] })).promise
  const a = await samples(silent.path), b = await samples(separate.path)
  const energy = values => values.reduce((sum, value) => sum + value * value, 0)
  assert.ok(energy(b.values) > energy(a.values))
  assert.deepEqual(separate.soundfont.ports, [0, 1])
}))

test('the source plan retains tempo/SMPTE positions and last-block expression before separate engine quantization', () => {
  const performance = midiSourceFromEvents([channel(0, [0x90, 60, 100]), meta(480, 0x51, [15, 66, 64]),
    channel(959, [0xb0, 7, 20]), channel(959, [0xb0, 7, 30]), channel(960, [0x80, 60, 0]), meta(960, 0x2f, [])], { ppq: 960 })
  const plan = fluidRenderPlan(performance)
  assert.equal(plan.frames, 33075)
  assert.deepEqual(plan.ports[0].events.map(event => event.frame), [0, 33030, 33030, 33075])
  assert.deepEqual(plan.ports[0].events.slice(1, 3).map(event => event.bytes[2]), [20, 30])
  const bytes = Buffer.from('4d5468640000000600000001e7284d54726b0000000d00903c648360803c0000ff2f00', 'hex')
  const smpte = fluidRenderPlan(importMidiSource(bytes))
  assert.equal(smpte.frames, 21168); assert.equal(smpte.ports[0].events[1].frame, 21168)
})

test('actual PCM follows the reported engine quantum; collapsed notes and events past the finite horizon are refused', () => fixture(async ({ sound, render }) => {
  const quantum = sound.engine.controlFrames
  const port = frame => ({ port: 0, events: [{ frame: 0, bytes: [0xc0, 0] }, { frame, bytes: [0x90, 60, 100] }] })
  const a = await (await render(source(), 'at-zero', { frames: quantum * 4, ports: [port(0)] })).promise
  const b = await (await render(source(), 'at-one', { frames: quantum * 4, ports: [port(1)] })).promise
  const onset = async result => { const { values } = await samples(result.path); return Math.floor(values.findIndex(value => value !== 0) / 2) }
  assert.equal(await onset(b) - await onset(a), quantum)
  assert.deepEqual(b.soundfont.timing.events, [[0, 0, 0], [0, 1, quantum]])
  assert.equal(b.soundfont.timing.maxDelayFrames, quantum - 1)
  const end = quantum * 2 - 1
  await assert.rejects((await render(source(), 'past-end', { frames: end, ports: [port(end - 1)] })).promise, /horizon/)
  await assert.rejects((await render(source(), 'collapsed', { frames: quantum * 4,
    ports: [{ port: 0, events: [...port(1).events, { frame: 2, bytes: [0x80, 60, 0] }] }] })).promise, /collapses/)
  await assert.rejects((await render(source(), 'mode-collapsed', { frames: quantum * 4, ports: [{ port: 0,
    events: [...port(1).events, { frame: quantum + 1, bytes: [0xb0, 120, 0] },
      { frame: quantum + 2, bytes: [0x90, 60, 100] }, { frame: quantum + 3, bytes: [0x80, 60, 0] }] }] })).promise, /collapses/)
}))

test('native errors do not overwrite existing targets; unsupported SysEx is refused and private font is retired', () => fixture(async ({ root, render }) => {
  const existing = join(root, 'existing.wav'); await writeFile(existing, 'keep')
  await assert.rejects((await render(source(), 'existing')).promise, /exist/i)
  assert.equal(await readFile(existing, 'utf8'), 'keep')
  const before = (await readdir(root)).filter(name => name.startsWith('soundfont-'))
  const plan = fluidRenderPlan(source())
  plan.ports[0].events.unshift({ frame: 0, bytes: [0xf0, 0x7d, 1, 0xf7] })
  await assert.rejects((await render(source(), 'sysex', { ports: plan.ports })).promise, /SysEx/)
  assert.deepEqual((await readdir(root)).filter(name => name.startsWith('soundfont-')), before)
  await assert.rejects(readFile(join(root, 'sysex.wav')), { code: 'ENOENT' })
}))

test('a positive source loop with no PCM sample is refused before publication', () => fixture(async ({ root, render }) => {
  const input = midiSourceFromEvents([channel(0, [0x90, 60, 100]), channel(65534, [0x80, 60, 0]), meta(65534, 47, [])], { ppq: 32767 })
  const { sourceWindow } = fluidRenderPlan(input, { loop: true, sourceLoop: { start: 3, end: 4 } })
  await assert.rejects((await render(input, 'tiny-window', { sourceWindow })).promise, /PCM window/)
  await assert.rejects(readFile(join(root, 'tiny-window.wav')), { code: 'ENOENT' })
}))
