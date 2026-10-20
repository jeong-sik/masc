import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { PPQ } from './sequencer-project.mjs'
import { practiceRange } from './practice-source.mjs'
import { monitorPacket } from './step-monitor-session.mjs'
import { importMidiSource, midiSourcePattern } from './midi-source.mjs'

midiFiles(JZZ)

// An explicit editable projection, never a replacement for the raw source.
// Use SMF's representable tempo for both timestamps and the conductor event.
export function practiceMidi(asset, context, packets, { signal } = {}) {
  const range = practiceRange(asset), clock = asset.metadata.input.clock
  const micros = Math.round(60e6 / context.backing.tempo)
  const n = BigInt(clock.numer) * BigInt(PPQ), d = BigInt(clock.denom) * BigInt(micros) * 1000n
  const at = host => {
    const value = (host * n * 2n + d) / (2n * d)
    if (value > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('Practice MIDI tick is not representable')
    return Number(value)
  }
  const file = new JZZ.MIDI.SMF(0, PPQ), track = new JZZ.MIDI.SMF.MTrk()
  file.push(track)
  track.add(0, JZZ.MIDI.smfTempo(micros)).add(0, JZZ.MIDI.smfTimeSignature(...context.project.meter))
  for (const bytes of context.backing.initial) track.add(0, JZZ.MIDI(bytes))
  packets = [...packets].sort((a, b) => BigInt(a.hostTime) < BigInt(b.hostTime) ? -1 : BigInt(a.hostTime) > BigInt(b.hostTime) ? 1 : 0)
  let held = new Map()
  for (const packet of packets) {
    signal?.throwIfAborted()
    const tick = at(BigInt(packet.hostTime) - BigInt(range.origin))
    const projected = monitorPacket(packet, context.backing.channel, held); held = projected.held
    for (const message of projected.messages) track.add(tick, JZZ.MIDI(message.bytes))
  }
  const end = Math.max(1, at(BigInt(range.extent))), channel = context.backing.channel
  for (const pitch of held.values()) track.add(end, JZZ.MIDI.noteOff(channel, pitch))
  for (const pedal of [64, 66, 69]) track.add(end, JZZ.MIDI.control(channel, pedal, 0))
  track.add(end, JZZ.MIDI.smfEndOfTrack())
  const source = importMidiSource(file.toUint8Array(), { name: asset.name + ' MIDI1 variant', sound: structuredClone(context.project.sound) })
  const performance = midiSourcePattern(source)
  if (!performance.notes.length) throw new Error('Practice MIDI projection has no notes to edit')
  if (performance.diagnostics.length) throw new Error('Practice MIDI projection has ambiguous note pairing')
  signal?.throwIfAborted()
  return source
}
