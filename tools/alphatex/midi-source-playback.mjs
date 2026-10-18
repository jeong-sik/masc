import { midiSourcePattern } from './midi-source.mjs'

function destination(value) {
  if (typeof value !== 'string' || !/^-?(0|[1-9][0-9]*)$/.test(value)
      || BigInt(value) < -2147483648n || BigInt(value) > 2147483647n || String(Number(value)) !== value) {
    throw new Error('MIDI output requires an exact signed 32-bit destination ID')
  }
  return value
}

// Keep the wire stream, including F7 escape/continuation payloads. Meta events
// influence source timing/routing but are never transmitted as MIDI status FF.
export function sourceMidiTimeline(source, { pattern, midiOutput, portBindings = [], loop = false } = {}) {
  if (loop) throw new Error('Source audition plays once from the beginning; clip looping requires state reconstruction')
  const performance = midiSourcePattern(source, { pattern })
  const events = performance.events.flatMap(event => {
    if (event.kind === 'meta') return []
    const bytes = event.kind === 'channel' ? event.bytes
      : event.status === 0xf0 ? [0xf0, ...event.data] : event.data
    return bytes.length ? [{ seconds: event.seconds, port: event.port, bytes: [...bytes] }] : []
  })
  const ports = [...new Set(events.map(event => event.port))].sort((a, b) => a - b)
  if (!ports.length) throw new Error('Selected MIDI pattern has no wire messages to play')
  if (!Array.isArray(portBindings)) throw new Error('Invalid MIDI source port bindings')
  if (midiOutput !== undefined && portBindings.length) throw new Error('Choose one output or explicit source port bindings')
  let bindings
  if (midiOutput !== undefined) {
    if (ports.length !== 1) throw new Error(`Bind each source MIDI port explicitly with :midi-port PORT ID (${ports.join(', ')})`)
    bindings = [{ port: ports[0], destination: destination(midiOutput) }]
  } else {
    bindings = portBindings.map(binding => {
      if (!Number.isInteger(binding?.port) || binding.port < 0 || binding.port > 127) throw new Error('Invalid MIDI source port')
      return { port: binding.port, destination: destination(binding.destination) }
    }).sort((a, b) => a.port - b.port)
  }
  if (bindings.length !== ports.length || bindings.some((binding, index) => binding.port !== ports[index])) {
    throw new Error(`Select an output for every source MIDI port (${ports.join(', ')})`)
  }
  if (new Set(bindings.map(binding => binding.destination)).size !== bindings.length) {
    throw new Error('Distinct source ports require distinct destinations; merged MIDI wire state is not supported')
  }
  return { schemaVersion: 2, duration: performance.seconds, bindings, events }
}

export function sourceTickAtSeconds(performance, seconds) {
  if (!performance || seconds <= 0) return 0
  const events = performance.events
  let low = 0, high = events.length
  while (low < high) {
    const mid = Math.floor((low + high) / 2)
    if (events[mid].seconds <= seconds) low = mid + 1
    else high = mid
  }
  const before = events[low - 1], after = events[low]
  if (!before) return 0
  if (!after) return performance.ticks
  return before.tick + (after.tick - before.tick) * (seconds - before.seconds) / (after.seconds - before.seconds)
}

export function sourceSecondsAtTick(performance, tick) {
  if (!performance || !Number.isFinite(tick) || tick < 0 || tick > performance.ticks) throw new Error('Seek must be within the source MIDI ticks')
  if (tick === performance.ticks) return performance.seconds
  const events = performance.events
  let low = 0, high = events.length
  while (low < high) {
    const mid = Math.floor((low + high) / 2)
    if (events[mid].tick <= tick) low = mid + 1
    else high = mid
  }
  const before = events[low - 1] ?? { tick: 0, seconds: 0 }, after = events[low]
  if (!after) return before.seconds
  return before.seconds + (after.seconds - before.seconds) * (tick - before.tick) / (after.tick - before.tick)
}
