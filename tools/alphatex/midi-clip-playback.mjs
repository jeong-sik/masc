import { createHash } from 'node:crypto'
import { midiClipClock, validateMidiClip } from './midi-clip-source.mjs'

export class MidiClipPlaybackRefusal extends Error {
  constructor(kind, message) { super(message); this.name = 'MidiClipPlaybackRefusal'; this.kind = kind }
}
const uint64Maximum = 0xffffffffffffffffn
const hash = value => createHash('sha256').update(value).digest('hex')
const destinationID = value => typeof value === 'string' && /^(0|-?[1-9][0-9]*)$/.test(value)
  && BigInt(value) >= -2147483648n && BigInt(value) <= 2147483647n
export function validateMidiClipDestination(value) {
  if (!destinationID(value)) throw new Error('Choose an exact CoreMIDI destination ID')
  return value
}

// The source retains musical ticks. This derived native schedule carries exact
// absolute nanosecond fractions, rounded once by its actual output owner.
export function midiClipPlaybackPlan(document, { destination, initialTempo } = {}) {
  validateMidiClipDestination(destination)
  validateMidiClip(document)
  const clock = midiClipClock(document, { initialTempo })
  if (clock.prefix.length) throw new MidiClipPlaybackRefusal('profile-negotiation-required',
    'This Clip has untimed setup requiring explicit MIDI-CI/Profile negotiation before playback')
  const denominator = clock.sequence.duration.denominator
  const setup = BigInt(clock.configuration.duration.numerator)
  const duration = setup + BigInt(clock.sequence.duration.numerator)
  const exact = numerator => {
    const divisor = BigInt(denominator)
    if (numerator / divisor + (numerator % divisor ? 1n : 0n) >= uint64Maximum) {
      throw new MidiClipPlaybackRefusal('native-clock-range', 'Clip playback exceeds the native nanosecond clock')
    }
    return { numerator: String(numerator), denominator }
  }
  const project = (event, section, offset) => {
    const type = event.words[0] >>> 28, utility = event.words[0] >>> 20 & 15
    if (type === 0 && [1, 2].includes(utility)) throw new MidiClipPlaybackRefusal('embedded-clock',
      'JR Clock/Timestamp messages require explicit clock coordination before Clip playback')
    return { id: event.id, section, tick: event.tick, words: [...event.words],
      nanoseconds: exact(offset + BigInt(event.nanoseconds.numerator)) }
  }
  return { schemaVersion: 1, kind: 'midi-clip-playback',
    source: { originalSha256: document.original.sha256, documentSha256: hash(JSON.stringify(document)), ppq: Number(denominator) },
    destination, setupNanoseconds: exact(setup), durationNanoseconds: exact(duration),
    events: [...clock.configuration.events.map(event => project(event, 'configuration', 0n)),
      ...clock.sequence.events.map(event => project(event, 'sequence', setup))] }
}

export function clipRoundedNanoseconds(value) {
  const n = BigInt(value.numerator), d = BigInt(value.denominator)
  return n / d + (n % d ? 1n : 0n)
}

// Locate one immutable source event within the admitted playback snapshot.
export function midiClipEventNanoseconds(plan, id) {
  const event = plan.events.find(event => event.id === id)
  if (!event) throw new Error('Selected event is absent from the admitted Clip playback snapshot')
  return String(clipRoundedNanoseconds(event.nanoseconds))
}
