import { sequenceEvents, PPQ } from './sequencer-project.mjs'

// The native sender consumes the same clipped schedule as MIDI/WAV export.
// This is a project projection, not an importer that drops unknown MIDI data.
export function projectMidiTimeline(project, options) {
  const { events, seconds } = sequenceEvents(project, options)
  return { schemaVersion: 1, duration: seconds, events: events.map(({ tick, track, ...event }) =>
    ({ ...event, seconds: tick / PPQ * 60 / project.tempo })) }
}
