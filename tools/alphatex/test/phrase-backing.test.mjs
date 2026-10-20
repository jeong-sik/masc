import test from 'node:test'
import assert from 'node:assert/strict'
import { newProject } from '../sequencer-project.mjs'
import { phraseBacking, backingClock } from '../phrase-backing.mjs'

test('practice backing clips its selected range and honors other-track solo/mute without mutating the phrase', () => {
  const project = newProject()
  project.tempo = 120; project.loop = { start: 960, end: 1920 }
  project.tracks.push({ ...project.tracks[0], id: 'bass', channel: 1, solo: true,
    notes: [{ id: 'long', pitch: 48, start: 0, duration: 2880, velocity: 80 }] })
  project.tracks.push({ ...project.tracks[1], id: 'muted', channel: 2, muted: true })
  const before = structuredClone(project), plan = phraseBacking(project, 'track-1', true)
  assert.deepEqual(project, before)
  project.tracks[1].notes[0].pitch = 99
  const clock = backingClock(plan, 48000)
  const opening = clock.block('0', 24000)
  assert.deepEqual(opening.filter(row => (row.bytes[0] >>> 4) === 9), [{frame:0,bytes:[0x91,48,80]}])
  const edge = clock.block('24000', 16)
  assert.deepEqual(edge.filter(row => row.bytes[1] === 48).map(row => row.bytes), [[0x81,48,0],[0x91,48,80]])
  assert.deepEqual(plan.channels, [1])
  assert.throws(() => clock.block('24000', 16), /Discontinuous/)
})

test('sub-frame practice notes fail at device preparation rather than becoming held notes', () => {
  const project = newProject()
  project.tempo = 60000000
  project.tracks.push({ ...project.tracks[0], id: 'fast', channel: 1,
    notes: [{ id: 'tiny', pitch: 48, start: 0, duration: 1, velocity: 80 }] })
  assert.throws(() => backingClock(phraseBacking(project, 'track-1'), 48000), /shorter than one output frame/)
})
