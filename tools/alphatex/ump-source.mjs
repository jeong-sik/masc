import { unpackMidi } from './session-data.mjs'
import { chordVoicing } from './sequencer-project.mjs'
import { Chord, Note } from 'tonal'

const integer = (value, maximum, name) => {
  if (!Number.isSafeInteger(value) || value < 0 || value > maximum) throw new Error(`Invalid UMP ${name}`)
  return value
}
const fields = (value, allowed) => value && typeof value === 'object' && !Array.isArray(value)
  && Object.keys(value).every(key => allowed.includes(key))
export function validateUmpEdits(value, midiSha256) {
  if (value === undefined) return
  if (!fields(value, ['schemaVersion', 'midiSha256', 'notes']) || value.schemaVersion !== 1
      || value.midiSha256 !== midiSha256 || !Array.isArray(value.notes)) throw new Error('UMP edits disagree with their original MIDI source')
  const identities = new Set()
  for (const edit of value.notes) {
    if (!fields(edit, ['packet', 'word', 'pitch', 'velocity']) || !Object.hasOwn(edit, 'packet') || !Object.hasOwn(edit, 'word')
        || !Object.hasOwn(edit, 'pitch') && !Object.hasOwn(edit, 'velocity')) throw new Error('Invalid UMP note edit')
    integer(edit.packet, Number.MAX_SAFE_INTEGER, 'packet identity'); integer(edit.word, Number.MAX_SAFE_INTEGER, 'word identity')
    for (const field of ['pitch', 'velocity']) if (Object.hasOwn(edit, field)) integer(edit[field], 65535, field)
    const id = `${edit.packet}:${edit.word}`
    if (identities.has(id)) throw new Error('Duplicate UMP note edit')
    identities.add(id)
  }
}

// Packet index and word offset address immutable original messages, never a
// sorted display row, floating-point second or a MIDI1 note projection.
export function umpSourceEvents(packets) {
  const events = []
  packets.forEach((packet, index) => {
    if (typeof packet.hostTime !== 'string' || !/^(0|[1-9][0-9]*)$/.test(packet.hostTime)
        || BigInt(packet.hostTime) > 0xffffffffffffffffn || !packet.words?.length) throw new Error('Invalid UMP source host time or packet')
    let word = 0
    for (const message of unpackMidi(packet)) {
      const words = packet.words.slice(word, word + message.length / 4)
      events.push({ id: `${index}:${word}`, packet: index, word, hostTime: packet.hostTime, source: packet.source,
        type: message[0] >>> 4, group: message[0] & 15, status: message[1] >>> 4, channel: message[1] & 15, words })
      word += words.length
    }
  })
  return events
}
function noteOn(event) {
  if (event?.type !== 4 || event.status !== 9 || (event.words[0] >>> 8 & 255) > 127) throw new Error('Select a native MIDI2 NoteOn')
  return event
}
export function materializeUmp(packets, edits, midiSha256) {
  validateUmpEdits(edits, midiSha256)
  const originals = new Map(umpSourceEvents(packets).map(event => [event.id, event])), changed = new Map()
  for (const edit of edits?.notes ?? []) {
    const event = noteOn(originals.get(`${edit.packet}:${edit.word}`)), words = [...event.words]
    if (Object.hasOwn(edit, 'pitch')) {
      const attribute = words[0] & 255
      if (![0, 3].includes(attribute)) throw new Error('Absolute pitch cannot overwrite manufacturer, Profile or unknown note attributes')
      if (attribute === 0 && (words[1] & 65535)) throw new Error('Invalid original MIDI2 no-attribute data')
      words[0] = ((words[0] & 0xffffff00) | 3) >>> 0
      words[1] = ((words[1] & 0xffff0000) | edit.pitch) >>> 0
    }
    if (Object.hasOwn(edit, 'velocity')) words[1] = (edit.velocity * 65536 + (words[1] & 65535)) >>> 0
    let packet = changed.get(event.packet)
    if (!packet) { packet = { ...packets[event.packet], words: [...packets[event.packet].words] }; changed.set(event.packet, packet) }
    packet.words.splice(event.word, words.length, ...words)
  }
  return packets.map((packet, index) => changed.get(index) ?? packet)
}
export function umpSourceNotes(packets, edits, midiSha256) {
  const result = materializeUmp(packets, edits, midiSha256)
  return umpSourceEvents(result).filter(event => event.type === 4 && event.status === 9).map(event => {
    noteOn(event)
    const index = event.words[0] >>> 8 & 127, attribute = event.words[0] & 255
    return { ...event, index, attribute, velocity: event.words[1] >>> 16,
      pitch: attribute === 3 ? event.words[1] & 65535 : index * 512,
      basis: attribute === 3 ? 'absolute-attribute' : attribute === 0 ? 'key-index' : 'opaque-attribute' }
  })
}
export function umpVariantAsset(asset, packets, ump) {
  materializeUmp(packets, ump, asset.parts.midi.sha256)
  const variant = { ...asset, name: `${asset.name} UMP variant` }
  if (ump === undefined) delete variant.ump
  else variant.ump = structuredClone(ump)
  delete variant.selectedTake
  return variant
}
export function editUmpNotes(packets, current, midiSha256, changes) {
  validateUmpEdits(current, midiSha256)
  const notes = new Map((current?.notes ?? []).map(note => [`${note.packet}:${note.word}`, { ...note }]))
  const events = new Map(umpSourceEvents(packets).map(event => [event.id, event]))
  const seen = new Set()
  for (const change of changes) {
    if (seen.has(change.id)) throw new Error('Duplicate UMP note decision')
    seen.add(change.id)
    const event = noteOn(events.get(change.id))
    if (change.kind === 'reset') notes.delete(event.id)
    else {
      if (change.kind !== 'note' || !fields(change, ['kind', 'id', 'pitch', 'velocity'])) throw new Error('Unknown UMP note decision')
      const next = { ...(notes.get(event.id) ?? { packet: event.packet, word: event.word }) }
      for (const field of ['pitch', 'velocity']) if (Object.hasOwn(change, field)) next[field] = change[field]
      notes.set(event.id, next)
    }
  }
  const result = { schemaVersion: 1, midiSha256, notes: [...notes.values()].sort((a, b) => a.packet - b.packet || a.word - b.word) }
  materializeUmp(packets, result, midiSha256)
  return result
}
export function umpOnset(notes, id) {
  const selected = notes.find(note => note.id === id)
  if (!selected) throw new Error('Select a native MIDI2 note')
  return notes.filter(note => note.source === selected.source && note.group === selected.group && note.channel === selected.channel
    && note.hostTime === selected.hostTime).sort((a, b) => a.pitch - b.pitch || a.packet - b.packet || a.word - b.word)
}
export function umpOnsetHarmony(notes, id) {
  const voices = umpOnset(notes, id), pitches = voices.map(note => note.pitch)
  if (voices.some(note => note.basis === 'opaque-attribute')) return { kind: 'opaque-attribute', pitches, candidates: [] }
  if (pitches.some(value => value % 512)) return { kind: 'fractional-pitch', pitches, candidates: [] }
  return { kind: voices.every(note => note.basis === 'absolute-attribute') ? 'absolute-attribute' : 'key-index-candidates', pitches,
    candidates: Chord.detect(pitches.map(value => Note.fromMidi(value / 512))) }
}
export function revoiceUmpNotes(packets, current, midiSha256, id, symbol, options) {
  const notes = umpOnset(umpSourceNotes(packets, current, midiSha256), id)
  const pitches = chordVoicing(symbol, options)
  if (pitches.length !== notes.length) throw new Error('Voicing must match the exact onset voice count')
  return editUmpNotes(packets, current, midiSha256, notes.map((note, index) => ({ kind: 'note', id: note.id, pitch: pitches[index] * 512 })))
}

// Decimal MIDI-note units are exact Q7.9 values, not a rounded Number pitch.
export function absoluteUmpPitch(value) {
  const match = typeof value === 'string' && /^(\d+)(?:\.(\d+))?$/.exec(value)
  if (!match) throw new Error('Use a nonnegative absolute MIDI pitch in exact 1/512-semitone units')
  const divisor = 10n ** BigInt(match[2]?.length ?? 0)
  const scaled = (BigInt(match[1]) * divisor + BigInt(match[2] ?? '0')) * 512n
  if (scaled % divisor || scaled / divisor > 65535n) throw new Error('Absolute pitch must fit exact MIDI2 Pitch7.9')
  return Number(scaled / divisor)
}
