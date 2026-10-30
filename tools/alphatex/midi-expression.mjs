const integer = (value, name, maximum = 127) => {
  if (!Number.isSafeInteger(value) || value < 0 || value > maximum) throw new Error(`Invalid MIDI ${name}`)
  return value
}

// MIDI 1.0 channel voice encoding: https://midi.org/expanded-midi-1-0-messages-list
export function expressionMessage(message) {
  const channel = integer(message?.channel, 'channel', 15)
  switch (message.kind) {
    case 'cc': return [0xb0 | channel, integer(message.controller, 'controller'), integer(message.value, 'control value')]
    case 'bend': {
      const value = integer(message.value, 'pitch bend', 16383)
      return [0xe0 | channel, value & 127, value >> 7]
    }
    case 'program': return [0xc0 | channel, integer(message.value, 'program')]
    case 'pressure': return [0xd0 | channel, integer(message.value, 'channel pressure')]
    case 'poly-pressure': return [0xa0 | channel, integer(message.pitch, 'pressure key'), integer(message.value, 'key pressure')]
    default: throw new Error('Choose CC, bend, program, pressure or poly-pressure')
  }
}

export function expressionEvent(event) {
  if (event?.kind !== 'channel') return null
  const [status, first, second] = event.bytes, channel = status & 15
  let message
  switch (status & 0xf0) {
    case 0xb0: message = { kind: 'cc', controller: first, value: second }; break
    case 0xe0: message = { kind: 'bend', value: first + second * 128 }; break
    case 0xc0: message = { kind: 'program', value: first }; break
    case 0xd0: message = { kind: 'pressure', value: first }; break
    case 0xa0: message = { kind: 'poly-pressure', pitch: first, value: second }; break
    default: return null
  }
  return { ...message, channel, id: event.id, track: event.track, tick: event.tick, port: event.port }
}
