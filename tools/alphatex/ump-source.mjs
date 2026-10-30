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
  if (!fields(value, ['schemaVersion', 'midiSha256', 'notes', 'expressions', 'timing']) || value.schemaVersion !== 1
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
  if (Object.hasOwn(value, 'expressions') && !Array.isArray(value.expressions)) throw new Error('Invalid UMP expression edits')
  for (const edit of value.expressions ?? []) {
    if (!fields(edit, ['packet', 'word', 'value']) || !['packet', 'word', 'value'].every(key => Object.hasOwn(edit, key))) throw new Error('Invalid UMP expression edit')
    integer(edit.packet, Number.MAX_SAFE_INTEGER, 'packet identity'); integer(edit.word, Number.MAX_SAFE_INTEGER, 'word identity')
    integer(edit.value, 0xffffffff, 'expression value')
    const id = `${edit.packet}:${edit.word}`
    if (identities.has(id)) throw new Error('Duplicate UMP edit identity')
    identities.add(id)
  }
  if (Object.hasOwn(value, 'timing') && !Array.isArray(value.timing)) throw new Error('Invalid UMP timing edits')
  const timed = new Set()
  for (const edit of value.timing ?? []) {
    if (!fields(edit, ['packet', 'word', 'hostTime']) || !['packet', 'word', 'hostTime'].every(key => Object.hasOwn(edit, key))) throw new Error('Invalid UMP timing edit')
    integer(edit.packet, Number.MAX_SAFE_INTEGER, 'packet identity'); integer(edit.word, Number.MAX_SAFE_INTEGER, 'word identity')
    hostTick(edit.hostTime)
    const id = `${edit.packet}:${edit.word}`
    if (timed.has(id)) throw new Error('Duplicate UMP timing edit')
    timed.add(id)
  }
}
function hostTick(value) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value) || BigInt(value) > 0xffffffffffffffffn) throw new Error('Use exact unsigned UInt64 host ticks')
  return BigInt(value)
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
export function umpAttackFields(words) {
  noteOn({ type: words[0] >>> 28, status: words[0] >>> 20 & 15, words })
  const index = words[0] >>> 8 & 127, attribute = words[0] & 255
  return { index, attribute, velocity: words[1] >>> 16, pitch: attribute === 3 ? words[1] & 65535 : index * 512,
    basis: attribute === 3 ? 'absolute-attribute' : attribute === 0 ? 'key-index' : 'opaque-attribute' }
}
export function editUmpAttackWords(original, { pitch, velocity }) {
  const words = [...original]; umpAttackFields(words)
  if (pitch !== undefined) {
    integer(pitch, 65535, 'absolute pitch')
    const attribute = words[0] & 255
    if (![0, 3].includes(attribute)) throw new Error('Absolute pitch cannot overwrite manufacturer, Profile or unknown note attributes')
    if (attribute === 0 && (words[1] & 65535)) throw new Error('Invalid original MIDI2 no-attribute data')
    words[0] = ((words[0] & 0xffffff00) | 3) >>> 0
    words[1] = ((words[1] & 0xffff0000) | pitch) >>> 0
  }
  if (velocity !== undefined) { integer(velocity, 65535, 'velocity'); words[1] = (velocity * 65536 + (words[1] & 65535)) >>> 0 }
  return words
}
// UMP 1.1.2 sections 7.4.3, 7.4.4 and 7.4.12: these four
// per-note messages own one complete 32-bit data word. Keep their address
// word and order; do not guess which attack a persistent controller belongs to.
function expressionKind(event) {
  if (event?.type !== 4 || (event.words[0] >>> 8 & 255) > 127) return
  switch (event.status) {
    case 0: return 'registered-per-note'
    case 1: return 'assignable-per-note'
    case 6: return (event.words[0] & 255) === 0 ? 'per-note-pitch-bend' : undefined
    case 10: return (event.words[0] & 255) === 0 ? 'poly-pressure' : undefined
  }
}
function expression(event) {
  if (!expressionKind(event)) throw new Error('Select a native MIDI2 per-note controller, pitch bend or poly pressure message')
  return event
}
export function umpEditedEvents(packets, edits, midiSha256) {
  validateUmpEdits(edits, midiSha256)
  const originals = new Map(umpSourceEvents(packets).map(event => [event.id, { ...event, originalHostTime: event.hostTime }])), changed = new Map()
  function replace(event, words) {
    changed.set(event.id, { ...event, words })
  }
  for (const edit of edits?.notes ?? []) {
    const event = noteOn(originals.get(`${edit.packet}:${edit.word}`))
    replace(event, editUmpAttackWords(event.words, edit))
  }
  for (const edit of edits?.expressions ?? []) {
    const event = expression(originals.get(`${edit.packet}:${edit.word}`))
    replace(event, [event.words[0], edit.value])
  }
  const timed = new Map()
  const embeddedClocks = new Set([...originals.values()].filter(event => event.type === 0
    && [1, 2, 3, 4].includes(event.words[0] >>> 20 & 15)).map(event => event.source))
  for (const edit of edits?.timing ?? []) {
    const event = originals.get(`${edit.packet}:${edit.word}`)
    if (!event) throw new Error('Unknown original UMP timing identity')
    // JR and delta clock utilities give following messages another timebase.
    // Host-clock editing cannot silently contradict that embedded schedule.
    if (embeddedClocks.has(event.source)) throw new Error('Embedded JR/delta-clock timing requires its own timing editor')
    timed.set(event.id, edit.hostTime)
  }
  return [...originals.values()].map(event => ({ ...(changed.get(event.id) ?? event), hostTime: timed.get(event.id) ?? event.hostTime }))
}
export function materializeUmp(packets, edits, midiSha256) {
  const events = umpEditedEvents(packets, edits, midiSha256)
  if (!edits?.timing?.length) {
    const result = packets.map(packet => ({ ...packet, words: [...packet.words] }))
    for (const event of events) result[event.packet].words.splice(event.word, event.words.length, ...event.words)
    return result
  }
  // Stable original identity/order never comes from these derived packet rows.
  // Split complete messages only; ties retain original presentation order.
  return events.map((event, ordinal) => ({ event, ordinal }))
    .sort((a, b) => BigInt(a.event.hostTime) < BigInt(b.event.hostTime) ? -1 : BigInt(a.event.hostTime) > BigInt(b.event.hostTime) ? 1 : a.ordinal - b.ordinal)
    .map(({ event }) => {
      const original = packets[event.packet], result = { ...original, words: [...event.words], hostTime: event.hostTime }
      if (event.hostTime !== event.originalHostTime) Object.assign(result, { timestampOrigin: 'authored',
        recordedHostTime: original.recordedHostTime ?? event.originalHostTime,
        recordedTimestampOrigin: original.recordedTimestampOrigin ?? original.timestampOrigin })
      return result
    })
}
export function umpSourceExpressions(packets, edits, midiSha256) {
  return sourceExpressions(umpEditedEvents(packets, edits, midiSha256))
}
function sourceExpressions(events) {
  return events.flatMap(event => {
    const kind = expressionKind(event)
    return kind ? [{ ...event, kind, index: event.words[0] >>> 8 & 127, value: event.words[1],
      ...([0, 1].includes(event.status) ? { controller: event.words[0] & 255 } : {}) }] : []
  })
}
export function umpSourceNotes(packets, edits, midiSha256) {
  return sourceNotes(umpEditedEvents(packets, edits, midiSha256))
}
function sourceNotes(events) {
  return events.filter(event => event.type === 4 && event.status === 9).map(event => {
    return { ...event, ...umpAttackFields(event.words) }
  })
}
export function umpSourceView(packets, edits, midiSha256) {
  const events = umpEditedEvents(packets, edits, midiSha256)
  return { notes: sourceNotes(events), expressions: sourceExpressions(events), events }
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
  const result = { schemaVersion: 1, midiSha256, notes: [...notes.values()].sort((a, b) => a.packet - b.packet || a.word - b.word),
    ...(current?.timing?.length ? { timing: structuredClone(current.timing) } : {}),
    ...(current?.expressions?.length ? { expressions: structuredClone(current.expressions) } : {}) }
  materializeUmp(packets, result, midiSha256)
  return result
}
export function editUmpExpressions(packets, current, midiSha256, changes) {
  validateUmpEdits(current, midiSha256)
  const expressions = new Map((current?.expressions ?? []).map(edit => [`${edit.packet}:${edit.word}`, { ...edit }]))
  const events = new Map(umpSourceEvents(packets).map(event => [event.id, event])), seen = new Set()
  for (const change of changes) {
    if (seen.has(change.id)) throw new Error('Duplicate UMP expression decision')
    seen.add(change.id)
    const event = expression(events.get(change.id))
    if (change.kind === 'reset') expressions.delete(event.id)
    else {
      if (change.kind !== 'expression' || !fields(change, ['kind', 'id', 'value']) || !Object.hasOwn(change, 'value')) throw new Error('Unknown UMP expression decision')
      expressions.set(event.id, { packet: event.packet, word: event.word, value: change.value })
    }
  }
  const result = { schemaVersion: 1, midiSha256, notes: structuredClone(current?.notes ?? []),
    ...(current?.timing?.length ? { timing: structuredClone(current.timing) } : {}),
    ...(expressions.size ? { expressions: [...expressions.values()].sort((a, b) => a.packet - b.packet || a.word - b.word) } : {}) }
  materializeUmp(packets, result, midiSha256)
  return result
}
export function editUmpTimes(packets, current, midiSha256, changes) {
  validateUmpEdits(current, midiSha256)
  const events = new Map(umpSourceEvents(packets).map(event => [event.id, event]))
  const timing = new Map((current?.timing ?? []).map(edit => [`${edit.packet}:${edit.word}`, { ...edit }])), seen = new Set()
  for (const change of changes) {
    if (!fields(change, ['kind', 'id', 'hostTime']) || !['time', 'reset'].includes(change.kind) || seen.has(change.id)) throw new Error('Invalid UMP timing decision')
    seen.add(change.id)
    const event = events.get(change.id)
    if (!event) throw new Error('Unknown original UMP timing identity')
    if (change.kind === 'reset') timing.delete(event.id)
    else {
      hostTick(change.hostTime)
      if (change.hostTime === event.hostTime) timing.delete(event.id)
      else timing.set(event.id, { packet: event.packet, word: event.word, hostTime: change.hostTime })
    }
  }
  const result = { schemaVersion: 1, midiSha256, notes: structuredClone(current?.notes ?? []),
    ...(current?.expressions?.length ? { expressions: structuredClone(current.expressions) } : {}),
    ...(timing.size ? { timing: [...timing.values()].sort((a, b) => a.packet - b.packet || a.word - b.word) } : {}) }
  materializeUmp(packets, result, midiSha256)
  return result
}
export function editUmpNoteTime(packets, current, midiSha256, onID, offID, start, end) {
  if (hostTick(end) <= hostTick(start)) throw new Error('Note release must follow its attack')
  const events = new Map(umpSourceEvents(packets).map(event => [event.id, event]))
  const on = noteOn(events.get(onID)), off = events.get(offID)
  if (off?.type !== 4 || off.status !== 8 || on.source !== off.source || on.group !== off.group || on.channel !== off.channel
      || (on.words[0] >>> 8 & 255) !== (off.words[0] >>> 8 & 255)) throw new Error('Choose an explicit native MIDI2 NoteOff with the same source/group/channel/Note Index')
  return editUmpTimes(packets, current, midiSha256, [{ kind: 'time', id: onID, hostTime: start }, { kind: 'time', id: offID, hostTime: end }])
}
export function umpOnset(notes, id) {
  const selected = notes.find(note => note.id === id)
  if (!selected) throw new Error('Select a native MIDI2 note')
  return notes.filter(note => note.source === selected.source && note.group === selected.group && note.channel === selected.channel
    && note.hostTime === selected.hostTime).sort((a, b) => a.pitch - b.pitch || a.packet - b.packet || a.word - b.word)
}
export function umpOnsetHarmony(notes, id) {
  return umpPitchHarmony(umpOnset(notes, id))
}
export function umpPitchHarmony(voices) {
  const pitches = voices.map(note => note.pitch)
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
