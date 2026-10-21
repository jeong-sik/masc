import JZZ from 'jzz'
import { captureRange, captureRegionTime } from './capture-time.mjs'
import { unpackMidi } from './session-data.mjs'
import { midiSourceFromTracks, midiSourcePattern } from './midi-source.mjs'
import { PPQ } from './sequencer-project.mjs'
import { setImmediate as yieldInput } from 'node:timers/promises'

const meta = (type, data, tick = 0) => ({ tick, kind: 'meta', type, data })
const text = value => [...Buffer.from(value, 'utf8')]

// A declared MIDI1 experiment, alongside the immutable WAV/UMP take. Original
// host ticks own time; both projection and FF51 use the same integer SMF tempo.
export async function captureMidi(asset, packets, { tempo, meter, signal, region } = {}) {
  const range = captureRange(asset), clock = asset.manifest.clock
  if (region) captureRegionTime(asset, region)
  const micros = Math.round(60e6 / tempo)
  if (!Number.isSafeInteger(micros) || micros < 1 || micros > 0xffffff) throw new Error('Capture MIDI tempo exceeds SMF Set Tempo')
  const power = Math.log2(meter?.[1])
  if (!Number.isInteger(meter?.[0]) || meter[0] < 1 || meter[0] > 255 || !Number.isInteger(power) || power < 0 || power > 255) throw new Error('Capture MIDI meter exceeds SMF Time Signature')
  const n = BigInt(clock.numer) * BigInt(PPQ), d = BigInt(clock.denom) * BigInt(micros) * 1000n
  const tickAt = offset => {
    if (offset < 0n) throw new Error('Captured MIDI precedes its source span')
    const tick = (offset * n * 2n + d) / (2n * d)
    if (tick > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('Captured MIDI tick is not representable')
    return Number(tick)
  }
  const extent = region?.extent ?? range.extent
  const routes = new Map(), rows = region
    ? region.events.map(row => ({ offset: row.offset, packet: { kind: 'midi', protocol: 2, timestampOrigin: 'packet', source: row.source, words: row.words } }))
    : [...packets].sort((a, b) => BigInt(a.hostTime) < BigInt(b.hostTime) ? -1 : BigInt(a.hostTime) > BigInt(b.hostTime) ? 1 : 0)
      .map(packet => ({ offset: String(BigInt(packet.hostTime) - BigInt(range.origin)), packet }))
  let utilities = 0, midi2Messages = 0, emitted = []
  const converter = JZZ.M2M1().connect(message => emitted.push([...message]))
  try {
    for (const { offset: position, packet } of rows) {
      // A packet is the cancellation boundary. Let the worker receive Stop /
      // close requests even when all conversion work is otherwise synchronous.
      await yieldInput(undefined, { signal })
      signal?.throwIfAborted()
      const source = asset.manifest.midiSources.find(source => source.id === packet.source)
      if (!source) throw new Error('Captured MIDI source is not declared')
      const offset = BigInt(position), tick = tickAt(offset)
      if (offset >= BigInt(extent)) throw new Error('Captured MIDI exceeds its source span')
      for (const message of unpackMidi(packet)) {
        const type = message[0] >>> 4, group = message[0] & 15
        if (type === 0) {
          const status = message[1] >>> 4
          if (message[0] !== 0 || status > 4 || status < 4 && (message[1] & 15) !== 0
            || status === 0 && (message[2] || message[3])) throw new Error('Unknown or invalid captured UMP Utility message')
          utilities++; continue // Known transport utility remains in raw UMP, not a channel performance.
        }
        if (![1, 2, 3, 4].includes(type)) throw new Error('Captured UMP message has no supported MIDI1 projection; original take retained')
        const key = JSON.stringify([packet.source, group])
        let route = routes.get(key)
        if (!route) {
          if (routes.size >= 128) throw new Error('Independent captured sources/groups exceed SMF MIDI ports')
          route = { port: routes.size, source: packet.source, group, exclusive: false, dialects: new Map(), held: new Map(), events: [] }
          route.events.push(meta(3, text(`${source.name} · group ${group + 1}`)), meta(0x21, [route.port]))
          routes.set(key, route)
        }
        if (type === 3) {
          const phase = message[1] >>> 4, count = message[1] & 15, data = [...message].slice(2)
          if (phase > 3 || count > 6 || data.slice(0, count).some(byte => byte >= 128) || data.slice(count).some(byte => byte !== 0)
            || ([0, 1].includes(phase) ? route.exclusive : !route.exclusive)) throw new Error('Captured SysEx7 fragments are invalid or incomplete')
          route.events.push({ tick, kind: 'sysex', status: phase < 2 ? 0xf0 : 0xf7,
            data: [...data.slice(0, count), ...([0, 3].includes(phase) ? [0xf7] : [])] })
          route.exclusive = [1, 2].includes(phase)
          continue
        }
        if (type === 1) {
          const status = message[1], lengths = new Map([[0xf1, 1], [0xf2, 2], [0xf3, 1], [0xf6, 0], [0xf8, 0], [0xfa, 0], [0xfb, 0], [0xfc, 0], [0xfe, 0], [0xff, 0]])
          const count = lengths.get(status), data = [...message].slice(2)
          if (count === undefined || data.slice(0, count).some(byte => byte >= 128) || data.slice(count).some(byte => byte !== 0)) throw new Error('Invalid captured MIDI system message')
          if (route.exclusive && status < 0xf8) throw new Error('Captured system message interrupts an open SysEx7 stream')
          route.events.push({ tick, kind: 'sysex', status: 0xf7, data: [status, ...data.slice(0, count)] })
          continue
        }
        const status = message[1] >>> 4, channel = message[1] & 15
        if (route.exclusive) throw new Error('Captured channel message interrupts an open SysEx7 stream')
        if (route.dialects.has(channel) && route.dialects.get(channel) !== type) throw new Error('Mixed MIDI1/MIDI2 channel state needs separate experiments')
        route.dialects.set(channel, type)
        if (type === 2) {
          if (status < 8 || status > 14 || message[2] > 127 || message[3] > 127 || [12, 13].includes(status) && message[3] !== 0) throw new Error('Invalid captured MIDI1 channel message')
          // UMP pads two-byte Program/Pressure messages to one word. That pad
          // belongs to the packet, never to the original MIDI channel bytes.
          route.events.push({ tick, kind: 'channel', bytes: [...message].slice(1, [12, 13].includes(status) ? 3 : 4) })
          observeNote(route, route.events.at(-1).bytes)
          continue
        } else {
          midi2Messages++
          switch (status) {
            case 8: case 9:
              if (message[2] > 127 || message[3] || message[6] || message[7]) throw new Error('Captured MIDI2 note attributes cannot be represented in MIDI1')
              break
            case 10: case 11:
              if (message[2] > 127 || message[3]) throw new Error('Invalid captured MIDI2 controller')
              if (status === 11 && [0, 6, 32, 38, 96, 97, 98, 99, 100, 101].includes(message[2])) throw new Error('Captured MIDI2 compound controller has no supported MIDI1 projection')
              break
            case 12:
              if (message[2] || message[3] > 1 || message[4] > 127 || message[5] || message[6] > 127 || message[7] > 127 || !message[3] && (message[6] || message[7])) throw new Error('Invalid captured MIDI2 program/bank fields')
              break
            case 13: case 14:
              if (message[2] || message[3]) throw new Error('Invalid captured MIDI2 pressure/bend fields')
              break
            default: throw new Error('Captured per-note or registered MIDI2 expression has no supported MIDI1 projection')
          }
        }
        emitted = []
        await converter.send(message)
        if (!emitted.length) throw new Error('MIDI conversion omitted a captured channel message')
        for (const bytes of emitted) {
          // UMP v1.1.2 D.2.1: MIDI2 NoteOn with velocity zero remains an attack.
          if (type === 4 && status === 9 && bytes[2] === 0) bytes[2] = 1
          route.events.push({ tick, kind: 'channel', bytes })
          observeNote(route, bytes)
        }
      }
    }
  } finally { await converter.close() }
  signal?.throwIfAborted()
  if ([...routes.values()].some(route => route.exclusive)) throw new Error('Captured SysEx7 stream has no final fragment')
  const boundary = tickAt(BigInt(extent)), end = Math.max(1, boundary)
  if (region) for (const route of routes.values()) {
    // These are explicit trim releases, not captured performance messages.
    // The SMF container's positive minimum must not lengthen a sub-tick note.
    for (const note of route.held.values()) for (let count = 0; count < note.count; count++) {
      route.events.push({ tick: boundary, kind: 'channel', bytes: [0x80 | note.channel, note.pitch, 0] })
    }
    for (const channel of route.dialects.keys()) for (const pedal of [64, 66, 69]) {
      route.events.push({ tick: boundary, kind: 'channel', bytes: [0xb0 | channel, pedal, 0] })
    }
  }
  const provenance = { schemaVersion: 1, kind: 'capture-midi1-variant', asset: asset.id, parts: asset.parts,
    origin: range.origin, clock, tempoMicros: micros, ppq: PPQ,
    precision: 'nearest tick; MIDI2 channel values reduced to MIDI1', utilities, midi2Messages,
    ...(region ? { cut: { offset: region.offset, extent: region.extent }, trimEnd: 'held keys released with velocity zero; hold pedals off' } : {}),
    routes: [...routes.values()].map(({ port, source, group }) => ({ port, source, group })) }
  const conductor = [meta(0x51, [micros >> 16, micros >> 8 & 255, micros & 255]), meta(0x58, [meter[0], power, 24, 8]),
    meta(0x7f, text(JSON.stringify(provenance))), meta(0x2f, [], end)]
  const source = midiSourceFromTracks([conductor, ...[...routes.values()].map(route => [...route.events, meta(0x2f, [], end)])],
    { ppq: PPQ, name: `${asset.name}${region ? ' region' : ''} MIDI1 variant` })
  const performance = midiSourcePattern(source)
  if (!performance.notes.length) throw new Error('Captured MIDI projection has no notes to edit')
  if (performance.diagnostics.length) throw new Error('Captured MIDI projection has unmatched, overlapping or unclosed notes; original take retained')
  signal?.throwIfAborted()
  return source
}

function observeNote(route, bytes) {
  const channel = bytes[0] & 15, type = bytes[0] >>> 4, pitch = bytes[1], key = channel * 128 + pitch
  if (type === 9 && bytes[2] > 0) {
    route.held.set(key, { channel, pitch, count: (route.held.get(key)?.count ?? 0) + 1 })
  } else if (type === 8 || type === 9 && bytes[2] === 0) {
    const note = route.held.get(key)
    if (note?.count > 1) route.held.set(key, { ...note, count: note.count - 1 })
    else route.held.delete(key)
  }
}
