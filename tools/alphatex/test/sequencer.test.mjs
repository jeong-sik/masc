import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { newProject, editProject, chordVoicing, harmonyAt, sequenceEvents, PPQ } from '../sequencer-project.mjs'
import { saveProject, loadProject, projectMidi } from '../sequencer-files.mjs'
import { renderProject } from '../sequencer-audio.mjs'
import { readWaveMetadata } from '../wave-file.mjs'
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
