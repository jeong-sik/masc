import test from 'node:test'
import assert from 'node:assert/strict'
import { newProject, editProject, PPQ } from '../sequencer-project.mjs'
import { projectMidiTimeline } from '../sequencer-midi.mjs'

test('external MIDI projection preserves multitrack programs, levels, pans, mute/solo and clipped notes', () => {
  let p = newProject()
  p = editProject(p, 'track-1', { kind: 'note', pitch: 60, start: 0, duration: 8 * PPQ, velocity: 91 })
  p = editProject(p, 'track-1', { kind: 'track', name: 'Bass' })
  p = editProject(p, 'track-2', { kind: 'track-settings', program: 33, level: 80, pan: 32 })
  p = editProject(p, 'track-2', { kind: 'note', pitch: 38, start: 4 * PPQ, duration: PPQ, velocity: 102 })
  p = editProject(p, 'track-1', { kind: 'loop', start: 2 * PPQ, end: 6 * PPQ })
  const timeline = projectMidiTimeline(p, { loop: true })
  assert.equal(timeline.schemaVersion, 1)
  assert.equal(timeline.duration, 2.4)
  assert.deepEqual(timeline.events.filter(e => e.kind === 'on').map(e => [e.channel, e.pitch, e.seconds, e.velocity]),
    [[0, 60, 0, 91], [1, 38, 1.2, 102]])
  assert.deepEqual(timeline.events.filter(e => e.kind === 'off').map(e => [e.channel, e.pitch, e.seconds]), [[1, 38, 1.8], [0, 60, 2.4]])
  assert.ok(timeline.events.some(e => e.kind === 'program' && e.channel === 1 && e.program === 33))
  assert.ok(timeline.events.some(e => e.kind === 'control' && e.channel === 1 && e.controller === 7 && e.value === 80))
  assert.ok(timeline.events.some(e => e.kind === 'control' && e.channel === 1 && e.controller === 10 && e.value === 32))
  p = editProject(p, 'track-2', { kind: 'track-settings', solo: true })
  assert.ok(projectMidiTimeline(p).events.every(e => e.channel === 1))
  p = editProject(p, 'track-2', { kind: 'track-settings', muted: true })
  assert.deepEqual(projectMidiTimeline(p).events, [])
})
