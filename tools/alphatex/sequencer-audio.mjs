import * as alphaTab from '@coderline/alphatab'
import { readFileSync } from 'node:fs'
import { createMidiAudioExporter } from './engine.mjs'
import { writeExporterWave } from './audio.mjs'
import { sequenceEvents, PPQ } from './sequencer-project.mjs'

export function renderProject(project, path, { loop = false, soundfontPath, cancelled = () => false } = {}) {
  const schedule = sequenceEvents(project, { loop })
  const midi = new alphaTab.midi.MidiFile()
  midi.division = PPQ
  midi.addEvent(new alphaTab.midi.TempoChangeEvent(0, Math.round(60e6 / project.tempo)))
  for (const event of schedule.events) {
    const index = project.tracks.findIndex(track => track.id === event.track)
    const value = event.kind === 'program'
      ? new alphaTab.midi.ProgramChangeEvent(index, event.tick, event.channel, event.program)
      : event.kind === 'control'
        ? new alphaTab.midi.ControlChangeEvent(index, event.tick, event.channel, event.controller, event.value)
        : event.kind === 'on'
          ? new alphaTab.midi.NoteOnEvent(index, event.tick, event.channel, event.pitch, event.velocity)
          : new alphaTab.midi.NoteOffEvent(index, event.tick, event.channel, event.pitch, 0)
    midi.addEvent(value)
  }
  for (const [index] of project.tracks.entries()) midi.addEvent(new alphaTab.midi.EndOfTrackEvent(index, schedule.ticks))
  const exporter = createMidiAudioExporter(midi, { soundfont: soundfontPath ? readFileSync(soundfontPath) : undefined })
  return writeExporterWave(exporter, path, { cancelled,
    // Loop regions cut exactly at the musical boundary; ordinary exports keep release tails.
    frames: loop ? Math.round(schedule.seconds * 44100) : undefined })
}
