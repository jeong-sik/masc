import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { newProject, editProject, chordVoicing, harmonyAt, sequenceEvents, validateProject, PPQ } from '../sequencer-project.mjs'
import { saveProject, loadProject, projectMidi } from '../sequencer-files.mjs'
import { renderProject } from '../sequencer-audio.mjs'
import { readWaveMetadata } from '../wave-file.mjs'
import { writeExporterWave } from '../audio.mjs'
midiFiles(JZZ)
const edit = (project, change) => editProject(project, project.tracks[0].id, change)
const chord = (project, symbol = 'Cmaj7', extra = {}) => edit(project, { kind: 'chord', symbol, start: 0, duration: PPQ, velocity: 96, ...extra })

test('make a phrase, compare chord candidates and inversions without changing the original', () => {
  const original = newProject(), c = chord(original)
  assert.equal(original.tracks[0].notes.length, 0)
  assert.deepEqual(harmonyAt(c, 0).pitches, [60, 64, 67, 71])
  assert.ok(harmonyAt(c, 0).candidates.includes('Cmaj7'))
  assert.deepEqual(harmonyAt(c, PPQ).pitches, [])
  assert.deepEqual(chordVoicing('Cmaj7', { inversion: 1 }), [64, 67, 71, 72])
  assert.deepEqual(chordVoicing('Cmaj7', { mode: 'drop2' }), [55, 60, 64, 71])
  assert.equal(chordVoicing('Dm7', { mode: 'rootless', octave: 3 }).length, 4)
  const progression = edit(original, { kind: 'progression', symbols: ['Dm7', 'G7', 'Cmaj7'], start: 0, duration: 4 * PPQ, velocity: 80, mode: 'rootless', octave: 3 })
  assert.equal(progression.tracks[0].notes.length, 12)
  assert.ok(harmonyAt(progression, 4 * PPQ).pitches.length > 0)
})
test('edits reject overlap, invalid pitch and quantize beyond the document transactionally', () => {
  const p = chord(newProject())
  assert.throws(() => chord(p), /Overlapping/)
  assert.throws(() => edit(p, { kind: 'transpose', semitones: 100 }), /pitch/)
  assert.equal(p.tracks[0].notes[0].pitch, 60)
  const late = edit(newProject(), { kind: 'note', pitch: 60, start: 16 * PPQ - 1, duration: 1, velocity: 80 })
  assert.throws(() => edit(late, { kind: 'quantize', grid: PPQ }), /note start/)
  assert.throws(() => edit(p, { kind: 'length', value: 10 }), /loop|duration/)
})
test('note-name edits become numeric keys before overlap detection, save/reopen and MIDI export', async () => {
  const original = edit(newProject(), { kind: 'note', pitch: 62, start: 0, duration: PPQ, velocity: 80 })
  const id = original.tracks[0].notes[0].id
  const changed = edit(original, { kind: 'change-note', id, pitch: 'C4' })
  assert.equal(original.tracks[0].notes[0].pitch, 62)
  assert.equal(changed.tracks[0].notes[0].pitch, 60)
  const before = structuredClone(changed)
  assert.throws(() => edit(changed, { kind: 'note', pitch: 60, start: 0, duration: PPQ, velocity: 80 }), /Overlapping/)
  assert.deepEqual(changed, before)
  for (const key of ['pitch', 'start', 'duration', 'velocity']) {
    const malformed = structuredClone(changed)
    malformed.tracks[0].notes[0][key] = key === 'pitch' ? 'C4' : String(malformed.tracks[0].notes[0][key])
    assert.throws(() => validateProject(malformed), /Invalid note/)
    assert.throws(() => projectMidi(malformed), /Invalid note/)
    assert.throws(() => edit(changed, { kind: 'change-note', id, [key]: key === 'pitch' ? 'C99' : '1' }), /pitch|Invalid note/)
    assert.deepEqual(changed, before)
  }
  const dir = await mkdtemp(join(tmpdir(), 'masc-sequencer-note-'))
  try {
    const path = join(dir, 'phrase.json')
    await saveProject(path, changed)
    const { project } = await loadProject(path)
    assert.deepEqual(project, changed)
    const midi = new JZZ.MIDI.SMF(projectMidi(project))
    assert.deepEqual([...midi[1]].filter(e => e.isNoteOn()).map(e => [e.tt, e.getNote()]), [[0, 60]])
    assert.deepEqual([...midi[1]].filter(e => e.isNoteOff()).map(e => [e.tt, e.getNote()]), [[PPQ, 60]])
  } finally { await rm(dir, { recursive: true, force: true }) }
})
test('extended inversions retain the selected bass and unsupported rootless choices fail transactionally', () => {
  assert.equal(chordVoicing('C9', { inversion: 4 })[0], 74)
  assert.equal(chordVoicing('C13', { inversion: 4 })[0], 74)
  assert.equal(chordVoicing('C13', { inversion: 5 })[0], 81)
  assert.deepEqual(chordVoicing('C/E'), [64, 67, 72])
  assert.deepEqual(chordVoicing('Cmaj7/G'), [67, 71, 72, 76])
  assert.deepEqual(chordVoicing('Cmaj7/F#'), [54, 60, 64, 67, 71])
  for (const symbol of ['Cmaj7/B', 'Cmaj7/G', 'Cmaj7/F#', 'C/E']) {
    assert.throws(() => chordVoicing(symbol, { mode: 'rootless' }), /explicit slash-chord bass/)
  }
  for (const symbol of ['C9', 'C13']) assert.throws(() => chordVoicing(symbol, { mode: 'rootless' }), /No rootless voicing/)
  assert.throws(() => chordVoicing('Cmaj7', { mode: 'rootless', inversion: 1 }), /explicit inversion/)
  const original = newProject()
  assert.throws(() => edit(original, { kind: 'progression', symbols: ['Dm7', 'Cmaj7/B'], mode: 'rootless', start: 0, duration: PPQ, velocity: 80 }), /explicit slash-chord bass/)
  assert.deepEqual(original, newProject())
})
test('MIDI duration and melodic channel allocation cannot silently wrap or become drums', () => {
  let project = newProject()
  project.length = project.loop.end = 0x0fffffff
  const midi = new JZZ.MIDI.SMF(projectMidi(project))
  assert.equal([...midi[0]].find(event => event.isEOT()).tt, project.length)
  project.length = project.loop.end = 0x10000000
  assert.throws(() => projectMidi(project), /SMF delta-time range/)
  project = newProject()
  for (let i = 1; i < 15; i++) project = edit(project, { kind: 'track', name: `Voice ${i + 1}` })
  assert.equal(project.tracks.length, 15)
  assert.ok(project.tracks.every(track => track.channel !== 9))
  const before = structuredClone(project)
  assert.throws(() => edit(project, { kind: 'track', name: 'Extra voice' }), /15 melodic MIDI channels/)
  assert.deepEqual(project, before)
  project = edit(project, { kind: 'drum-track', name: 'Drums' })
  assert.equal(project.tracks.length, 16)
  assert.equal(project.tracks.at(-1).channel, 9)
  assert.equal(new JZZ.MIDI.SMF(projectMidi(project)).length, 17)
})
test('multitrack mute/solo and loop clipping match the MIDI file schedule', () => {
  let p = chord(newProject(), 'Dm7', { duration: 4 * PPQ })
  p = edit(p, { kind: 'track', name: 'Bass' })
  p = editProject(p, p.tracks[1].id, { kind: 'note', pitch: 38, start: 0, duration: 8 * PPQ, velocity: 90 })
  p = edit(p, { kind: 'loop', start: PPQ, end: 2 * PPQ })
  const schedule = sequenceEvents(p, { loop: true })
  assert.equal(schedule.events.filter(e => e.kind === 'on').length, 5)
  assert.ok(schedule.events.filter(e => e.kind === 'on').every(e => e.tick === 0))
  assert.ok(schedule.events.filter(e => e.kind === 'off').every(e => e.tick === PPQ))
  const midi = new JZZ.MIDI.SMF(projectMidi(p, { loop: true }))
  assert.equal(midi.ppqn, PPQ)
  assert.equal(midi.length, 3)
  assert.deepEqual([...midi[2]].filter(e => e.isNoteOn()).map(e => [e.tt, e.getNote()]), [[0, 38]])
  p = editProject(p, p.tracks[1].id, { kind: 'track-settings', solo: true })
  assert.equal(sequenceEvents(p).events.filter(e => e.kind === 'on').length, 1)
  p = editProject(p, p.tracks[1].id, { kind: 'track-settings', muted: true })
  assert.equal(sequenceEvents(p).events.filter(e => e.kind === 'on').length, 0)
})
test('save/reopen retains exact phrase data and refuses stale or unrelated file overwrite', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'masc-sequencer-'))
  try {
    const path = join(dir, 'song.json'), project = chord(newProject())
    const revision = await saveProject(path, project)
    const reopened = await loadProject(path)
    assert.equal(reopened.revision, revision)
    assert.deepEqual(reopened.project, project)
    await assert.rejects(saveProject(path, newProject()), /EEXIST/)
    await writeFile(path, 'external edit')
    await assert.rejects(saveProject(path, project, revision), /changed on disk/)
    assert.equal(await readFile(path, 'utf8'), 'external edit')
  } finally { await rm(dir, { recursive: true, force: true }) }
})
test('rendered multitrack phrase has audible PCM and loop timing follows tempo', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'masc-sequencer-audio-'))
  try {
    const p = chord(newProject())
    p.loop.end = PPQ
    const result = renderProject(p, join(dir, 'loop.wav'), { loop: true })
    assert.ok(result.peak > 0.001)
    const meta = await readWaveMetadata(join(dir, 'loop.wav'))
    assert.equal(meta.frames, BigInt(Math.round(60 / p.tempo * 44100)))
    assert.ok(Math.abs(result.durationMs - 600) < 1)
  } finally { await rm(dir, { recursive: true, force: true }) }
})
test('track level and pan survive document and MIDI roundtrips and reject invalid edits transactionally', async () => {
  let project = chord(newProject())
  assert.deepEqual([project.tracks[0].level, project.tracks[0].pan], [100, 64])
  project = edit(project, { kind: 'track-settings', level: 80, pan: 0 })
  project = edit(project, { kind: 'track', name: 'Bass' })
  project = editProject(project, project.tracks[1].id, { kind: 'track-settings', level: 60, pan: 127 })
  const before = structuredClone(project)
  for (const key of ['level', 'pan']) for (const value of [-1, 128, 1.5, '64', null]) {
    assert.throws(() => edit(project, { kind: 'track-settings', [key]: value }), /Invalid track/)
    assert.deepEqual(project, before)
  }
  const schedule = sequenceEvents(project, { loop: true })
  assert.deepEqual(schedule.events.filter(event => event.kind === 'control').map(event => [event.tick, event.channel, event.controller, event.value]),
    [[0, 0, 7, 80], [0, 0, 10, 0], [0, 1, 7, 60], [0, 1, 10, 127]])
  const midi = new JZZ.MIDI.SMF(projectMidi(project, { loop: true }))
  for (const [index, track] of project.tracks.entries()) {
    assert.deepEqual([...midi[index + 1]].filter(event => event[0] >>> 4 === 0xb).map(event => [event.tt, event[0] & 15, event[1], event[2]]),
      [[0, track.channel, 7, track.level], [0, track.channel, 10, track.pan]])
  }
  const dir = await mkdtemp(join(tmpdir(), 'masc-sequencer-mix-'))
  try {
    const path = join(dir, 'mix.json')
    await saveProject(path, project)
    assert.deepEqual((await loadProject(path)).project, project)
  } finally { await rm(dir, { recursive: true, force: true }) }
})
test('measured phrase mixing exposes clipping and track controls change actual WAV level and stereo routing', async () => {
  let project = edit(newProject(), { kind: 'progression', symbols: ['Dm7', 'G7', 'Cmaj7'], mode: 'rootless', octave: 3, start: 0, duration: 4 * PPQ, velocity: 96 })
  project = edit(project, { kind: 'track', name: 'Bass' })
  const bass = project.tracks[1].id
  for (const [index, note] of ['D2', 'G2', 'C2'].entries()) {
    project = editProject(project, bass, { kind: 'note', pitch: note, start: index * 4 * PPQ, duration: 4 * PPQ, velocity: [110, 105, 100][index] })
  }
  const setLevel = (project, level) => project.tracks.reduce((result, track) => editProject(result, track.id, { kind: 'track-settings', level }), project)
  const dir = await mkdtemp(join(tmpdir(), 'masc-sequencer-level-'))
  try {
    const loud = renderProject(setLevel(project, 127), join(dir, 'loud.wav'))
    assert.ok(loud.peak > 1)
    assert.ok(loud.clippedSamples > 0)
    const mixed = renderProject(project, join(dir, 'mixed.wav'))
    assert.ok(mixed.peak > 0 && mixed.peak < 1)
    assert.equal(mixed.clippedSamples, 0)
    const silent = renderProject(setLevel(project, 0), join(dir, 'silent.wav'))
    assert.equal(silent.peak, 0)
    assert.equal(silent.clippedSamples, 0)
    let single = edit(newProject(), { kind: 'note', pitch: 60, start: 0, duration: PPQ, velocity: 96 })
    for (const pan of [0, 127]) {
      single = edit(single, { kind: 'track-settings', pan })
      const path = join(dir, `pan-${pan}.wav`)
      renderProject(single, path)
      const bytes = await readFile(path)
      const meta = await readWaveMetadata(path)
      const energy = [0, 0]
      for (let offset = meta.dataOffset; offset < meta.dataOffset + meta.dataBytes; offset += 4) {
        energy[0] += bytes.readInt16LE(offset) ** 2
        energy[1] += bytes.readInt16LE(offset + 2) ** 2
      }
      assert.ok(pan === 0 ? energy[0] > energy[1] : energy[1] > energy[0])
    }
    let rendered = false
    const result = writeExporterWave({ render() {
      if (rendered) return null
      rendered = true
      return { samples: Float32Array.from([1.25, -1.25, 1, -1, 0, 0]) }
    } }, join(dir, 'clipping-count.wav'))
    assert.equal(result.clippedSamples, 2)
    assert.equal(result.peak, 1.25)
  } finally { await rm(dir, { recursive: true, force: true }) }
})
