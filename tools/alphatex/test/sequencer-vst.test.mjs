import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { mkdtemp, readFile, writeFile, rm, access } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { newProject, editProject, PPQ } from '../sequencer-project.mjs'
import { importMidiSource, exportMidiSource, midiSourcePattern } from '../midi-source.mjs'
import { projectVstMidi, renderVstPhrase } from '../sequencer-vst.mjs'
midiFiles(JZZ)

const chunk = (name, data) => {
  const header = Buffer.alloc(8); header.write(name); header.writeUInt32BE(data.length, 4)
  return Buffer.concat([header, data])
}
const source = (tracks, format = 1, division = 480) => {
  const header = Buffer.alloc(6); header.writeUInt16BE(format); header.writeUInt16BE(tracks.length, 2); header.writeUInt16BE(division, 4)
  return importMidiSource(Buffer.concat([chunk('MThd', header), ...tracks.map(track => chunk('MTrk', Buffer.from(track)))]))
}
const track = pitch => [0, 255, 81, 3, 7, 161, 32, 0, 0xe0, 0, 65, 0, 0x90, pitch, 100,
  0x83, 0x60, 0x80, pitch, 0, 0, 255, 47, 0]
const phrase = () => editProject(newProject(), 'track-1', { kind: 'note', pitch: 60, start: 0, duration: PPQ * 2, velocity: 96 })
async function temporary(action) {
  const directory = await mkdtemp(join(tmpdir(), 'masc-phrase-vst-test-'))
  try { await action(directory) } finally { await rm(directory, { recursive: true, force: true }) }
}

test('the real worker prepares clipped loop notes as SMF without loading a SoundFont', async () => {
  await temporary(async directory => {
    const project = { ...phrase(), loop: { start: PPQ / 2, end: PPQ * 1.5 } }
    const worker = new Worker(new URL('../sequencer-worker.mjs', import.meta.url))
    const path = join(directory, 'phrase.mid'), cancel = new Int32Array(new SharedArrayBuffer(4))
    try {
      const reply = once(worker, 'message')
      worker.postMessage({ id: 1, project, path, cancel: cancel.buffer,
        options: { format: 'vst-midi', loop: true, soundfontPath: '/absent.sf2' } })
      const result = (await reply)[0]
      assert.equal(result.ok, true)
      assert.equal(result.result.format, 'vst-midi')
      const bytes = await readFile(path)
      assert.equal(new JZZ.MIDI.SMF(bytes).type, 1)
      const performance = midiSourcePattern(importMidiSource(bytes))
      assert.equal(performance.notes.length, 1)
      assert.equal(performance.notes[0].start, 0)
      assert.equal(performance.notes[0].duration, PPQ)
      assert.equal(result.result.duration, performance.seconds)
      Atomics.store(cancel, 0, 1)
      const cancelled = once(worker, 'message'), refused = join(directory, 'cancelled.mid')
      worker.postMessage({ id: 2, project, path: refused, cancel: cancel.buffer, options: { format: 'vst-midi' } })
      assert.equal((await cancelled)[0].ok, false)
      await assert.rejects(access(refused), { code: 'ENOENT' })
    } finally { await worker.terminate() }
  })
})

test('VST source audition selects SMF2 and converts SMPTE drop-frame without altering provenance', () => {
  const original = source([track(60), track(67)], 2)
  const before = exportMidiSource(original)
  const prepared = projectVstMidi(original, { pattern: 1 })
  const performance = midiSourcePattern(importMidiSource(prepared.bytes))
  assert.deepEqual(performance.notes.map(note => note.pitch), [67])
  assert.equal(performance.format, 0)
  assert.equal(performance.seconds, prepared.duration)
  assert.deepEqual(exportMidiSource(original), before)
  const smpte = source([track(64)], 0, (256 - 29) * 256 + 80)
  const expected = midiSourcePattern(smpte), converted = projectVstMidi(smpte)
  const actual = midiSourcePattern(importMidiSource(converted.bytes))
  assert.ok(Math.abs(actual.seconds - expected.seconds) < 1e-12)
  assert.deepEqual(actual.events.filter(event => event.kind === 'channel').map(event => event.bytes),
    expected.events.filter(event => event.kind === 'channel').map(event => event.bytes))
  assert.deepEqual(actual.notes.map(note => note.durationSeconds), expected.notes.map(note => note.durationSeconds))
})

test('distinct source ports cannot silently share one plugin state', () => {
  const multi = source([[0, 255, 0x21, 1, 1, ...track(60)], [0, 255, 0x21, 1, 2, ...track(64)]])
  assert.throws(() => projectVstMidi(multi), /separate instrument instances/)
})

for (const loop of [false, true]) test(`native rendering retains selection/MIDI and requests the correct tail (loop=${loop})`, async () => {
  await temporary(async directory => {
    const midi = join(directory, 'phrase.mid'), output = join(directory, 'render.wav'), stateDirectory = join(directory, 'state')
    const bytes = projectVstMidi(phrase()).bytes
    await writeFile(midi, bytes)
    const selection = { plugin_path: '/chosen.vst3', plugin_name: 'Bass', preset_path: '/chosen.vstpreset', name: 'Bass' }
    const requests = []
    const job = renderVstPhrase({ preparation: { promise: Promise.resolve({ path: midi, duration: 1 }), cancel: new Int32Array(new SharedArrayBuffer(4)) },
      selection, outputPath: output, stateDirectory, loop, run(request) {
        requests.push(request)
        return { cancel() {}, promise: writeFile(output, 'rendered').then(() => ({ output_path: output, duration_ms: 2000,
          midi_sha256: 'a'.repeat(64), wav_sha256: 'b'.repeat(64) })) }
      } })
    const wave = await job.promise
    assert.deepEqual(requests, [{ operation: 'render', ...selection, midi_path: midi, output_path: output, ...(loop ? { tail_seconds: 0 } : {}) }])
    await rm(midi); await rm(output)
    assert.deepEqual(await readFile(wave.vst.midi_path), Buffer.from(bytes))
    assert.equal(await readFile(wave.path, 'utf8'), 'rendered')
    assert.equal(wave.phraseDuration, 1)
    assert.equal(wave.duration, 2)
  })
})

test('cancellation retires preparation and a late native completion without fallback', async () => {
  await temporary(async directory => {
    const cancel = new Int32Array(new SharedArrayBuffer(4)); let finish, starts = 0
    const first = renderVstPhrase({ preparation: { promise: new Promise(resolve => { finish = resolve }), cancel },
      selection: {}, outputPath: 'unused', stateDirectory: directory, run() { starts++; assert.fail('cancelled preparation started a plugin') } })
    first.cancel(); finish({ path: 'unused' })
    await assert.rejects(first.promise, { code: 'ABORT_ERR' })
    assert.equal(Atomics.load(cancel, 0), 1); assert.equal(starts, 0)
    let complete, started, stops = 0
    const running = new Promise(resolve => { started = resolve })
    const second = renderVstPhrase({ preparation: { promise: Promise.resolve({ path: 'unused' }), cancel },
      selection: { plugin_path: '/chosen.vst3', plugin_name: null, preset_path: null, name: 'Chosen' }, outputPath: 'unused', stateDirectory: directory, run() {
        started(); return { promise: new Promise(resolve => { complete = resolve }), cancel() { stops++ } }
      } })
    await running; second.cancel(); complete({ output_path: 'unused' })
    await assert.rejects(second.promise, { code: 'ABORT_ERR' })
    assert.equal(stops, 1)
    await assert.rejects(access(join(directory, 'renders')), { code: 'ENOENT' })
  })
})
