import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { newProject, editProject, PPQ } from '../sequencer-project.mjs'
import { saveProject } from '../sequencer-files.mjs'
import { newArrangement } from '../arrangement.mjs'
import { projectVstMidi } from '../sequencer-vst.mjs'
import { importMidiSource } from '../midi-source.mjs'
import { readMusicInfo, inspectMusicEntry } from '../music-library-info.mjs'

const temporary = async action => {
  const root = await mkdtemp(join(tmpdir(), 'masc-library-info-'))
  try { await action(root) } finally { await rm(root, { recursive: true, force: true }) }
}

test('real worker reads the selected saved phrase without modifying it', async () => {
  await temporary(async root => {
    const path = join(root, 'opaque-id.json')
    const project = { ...editProject(newProject(), 'track-1', { kind: 'note', pitch: 60, start: 0, duration: PPQ, velocity: 96 }), title: '내 곡' }
    await saveProject(path, project)
    const bytes = await readFile(path), job = inspectMusicEntry({ kind: 'project', path })
    try {
      const info = await job.promise
      assert.equal(info.kind, 'phrase'); assert.equal(info.title, '내 곡')
      assert.equal(info.durationSeconds, 9.6)
      assert.equal(info.tracks[0].notes, 1); assert.equal(info.tracks[0].program, 0)
      assert.equal(info.revision.length, 64)
      await job.completion
      assert.deepEqual(await readFile(path), bytes)
    } finally { await job.cancel(); await job.completion }
  })
})

test('validated arrangement and source MIDI retain their different time domains', async () => {
  await temporary(async root => {
    const arrangement = join(root, 'arrangement.json')
    await saveProject(arrangement, newArrangement({ title: 'Backing', tempo: 80 }))
    const info = await readMusicInfo({ kind: 'project', path: arrangement })
    assert.equal(info.kind, 'arrangement'); assert.equal(info.tempo, 80)
    assert.equal(info.durationSeconds, 0); assert.equal(info.lanes, 0)
    const midi = join(root, 'source.json')
    await saveProject(midi, importMidiSource(projectVstMidi(newProject()).bytes, { name: 'Original performance' }))
    const source = await readMusicInfo({ kind: 'project', path: midi })
    assert.equal(source.kind, 'midi-source'); assert.equal(source.title, 'Original performance')
    assert.equal(source.patterns.length, 1)
    assert.equal(source.patterns[0].durationSeconds, 9.6)
    assert.equal(source.patterns[0].notes, 0)
  })
})

test('invalid documents remain errors, and immediate cancellation joins the actual worker', async () => {
  await temporary(async root => {
    const path = join(root, 'broken.json'); await writeFile(path, '{broken')
    const bad = inspectMusicEntry({ kind: 'project', path })
    await assert.rejects(bad.promise); await bad.completion
    const cancelled = inspectMusicEntry({ kind: 'project', path })
    const failure = assert.rejects(cancelled.promise, { code: 'ABORT_ERR' })
    await cancelled.cancel(); await failure; await cancelled.completion
  })
})

test('take details validate recorded data and preserve a failed capture outcome', async () => {
  await temporary(async path => {
    const wave = Buffer.alloc(44 + 480 * 2)
    wave.write('RIFF'); wave.writeUInt32LE(wave.length - 8, 4); wave.write('WAVEfmt ', 8); wave.writeUInt32LE(16, 16)
    wave.writeUInt16LE(1, 20); wave.writeUInt16LE(1, 22); wave.writeUInt32LE(48000, 24); wave.writeUInt32LE(96000, 28)
    wave.writeUInt16LE(2, 32); wave.writeUInt16LE(16, 34); wave.write('data', 36); wave.writeUInt32LE(wave.length - 44, 40)
    const manifest = { schemaVersion: 1, state: 'failed', failure: 'input disconnected', sampleRate: 48000,
      channels: 1, audioFrames: '480', midiPacketCount: '0', midiSources: [],
      clock: { kind: 'mach-host-time', numer: 1, denom: 1, requestedStart: '1000', firstAudioHostTime: '200001000' } }
    await writeFile(join(path, 'session.json'), JSON.stringify(manifest))
    await writeFile(join(path, 'audio.wav'), wave)
    await writeFile(join(path, 'audio-blocks.jsonl'), JSON.stringify({ kind: 'audio', hostTime: '200001000',
      deviceSampleTime: '0', frameOffset: '0', frameCount: 480, peaks: [[0, 0]] }) + '\n')
    await writeFile(join(path, 'midi.ump.jsonl'), '')
    const info = await readMusicInfo({ kind: 'session', path })
    assert.equal(info.kind, 'session'); assert.equal(info.state, 'failed')
    assert.equal(info.failure, 'input disconnected')
    assert.equal(info.frames, '480'); assert.ok(Math.abs(info.durationSeconds - 0.21) <= Number.EPSILON)
    manifest.audioFrames = '481'; await writeFile(join(path, 'session.json'), JSON.stringify(manifest))
    await assert.rejects(readMusicInfo({ kind: 'session', path }), /totals/)
  })
})
