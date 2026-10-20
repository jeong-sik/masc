import { PPQ } from './sequencer-project.mjs'
import { practiceRange } from './practice-source.mjs'
import { monitorPacket } from './step-monitor-session.mjs'
import { midiSourceFromEvents, midiSourcePattern } from './midi-source.mjs'

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
  const events = [
    { tick: 0, kind: 'meta', type: 0x51, data: [micros >> 16, micros >> 8 & 255, micros & 255] },
    { tick: 0, kind: 'meta', type: 0x58, data: [context.project.meter[0], Math.log2(context.project.meter[1]), 24, 8] },
  ]
  const add = (tick, bytes) => events.push({ tick, kind: 'channel', bytes })
  for (const bytes of context.backing.initial) add(0, [...bytes])
  packets = [...packets].sort((a, b) => BigInt(a.hostTime) < BigInt(b.hostTime) ? -1 : BigInt(a.hostTime) > BigInt(b.hostTime) ? 1 : 0)
  let held = new Map()
  for (const packet of packets) {
    signal?.throwIfAborted()
    const tick = at(BigInt(packet.hostTime) - BigInt(range.origin))
    const projected = monitorPacket(packet, context.backing.channel, held); held = projected.held
    for (const message of projected.messages) add(tick, message.bytes)
  }
  const end = Math.max(1, at(BigInt(range.extent))), channel = context.backing.channel
  for (const pitch of held.values()) add(end, [0x80 | channel, pitch, 0])
  for (const pedal of [64, 66, 69]) add(end, [0xb0 | channel, pedal, 0])
  events.push({ tick: end, kind: 'meta', type: 0x2f, data: [] })
  const source = midiSourceFromEvents(events, { ppq: PPQ, name: asset.name + ' MIDI1 variant', sound: structuredClone(context.project.sound) })
  const performance = midiSourcePattern(source)
  if (!performance.notes.length) throw new Error('Practice MIDI projection has no notes to edit')
  if (performance.diagnostics.length) throw new Error('Practice MIDI projection has ambiguous note pairing')
  signal?.throwIfAborted()
  return source
}
