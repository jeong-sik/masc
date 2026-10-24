import { createHash } from 'node:crypto'
import { umpMessages } from './ump-packets.mjs'
import { umpAttackFields, editUmpAttackWords, umpPitchHarmony } from './ump-source.mjs'
import { chordVoicing } from './sequencer-project.mjs'

const magic = Buffer.from('SMF2CLIP')
const hash = bytes => createHash('sha256').update(bytes).digest('hex')
const fields = (value, keys) => value && typeof value === 'object' && !Array.isArray(value)
  && Object.keys(value).every(key => keys.includes(key))
export function clipTick(value) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value)) throw new Error('Use an exact nonnegative MIDI Clip tick')
  return BigInt(value)
}

// Read the source envelope without JZZ Clip's recovery/normalization. JZZ UMP
// still owns message decoding. Simultaneous messages may share one delta stamp.
export function readMidiClip(input) {
  const bytes = Buffer.from(input)
  if (bytes.length < 8 || !bytes.subarray(0, 8).equals(magic)) throw new Error('Expected a MIDI2 Clip SMF2CLIP header')
  let ppq, phase = 'prefix', tick = 0n, delta = null, previousWasDelta = false, end = null, start = null
  const events = [], prefix = []
  let configurationTempo = null, configurationMeter = null, configurationPrevious = 'resolution'
  for (const row of umpMessages(bytes, 8)) {
    const { message, words, offset } = row
    if (end) throw new Error('MIDI Clip contains data after End of Clip')
    if (message.isDelta()) {
      if (previousWasDelta) throw new Error('Separate long MIDI Clip deltas with a NOOP')
      delta = message.getDelta()
      if (phase === 'prefix' && delta !== 0) throw new Error('MIDI Clip resolution requires a zero delta')
      tick += BigInt(delta); previousWasDelta = true
      continue
    }
    if (message.isTicksPQN()) {
      if (phase !== 'prefix' || !previousWasDelta || delta !== 0 || (words[0] & 0xffff0000) !== 0x00300000
          || !message.getTicksPQN()) throw new Error('MIDI Clip needs one positive DCTPQ after a zero delta')
      ppq = message.getTicksPQN(); phase = 'configuration'; previousWasDelta = false
      continue
    }
    if (phase === 'prefix') {
      // Untimed Profile-On negotiation is kept as original SysEx7 packets.
      // Import does not perform or invent a MIDI-CI exchange with a receiver.
      if (delta !== null || !message.isSX()) throw new Error('MIDI Clip needs its DCTPQ before timed data')
      prefix.push({ id: String(offset), offset, words, section: 'profile' }); continue
    }
    if (delta === null) throw new Error('MIDI Clip message has no delta clockstamp')
    previousWasDelta = false
    if (message.isStartClip()) {
      if (phase !== 'configuration') throw new Error('Repeated MIDI Clip Start of Clip')
      if (words[0] !== 0xf0200000 || words.slice(1).some(word => word !== 0)) throw new Error('Invalid MIDI Clip Start marker')
      start = { offset, configurationTicks: String(tick) }; tick = 0n; phase = 'sequence'; continue
    }
    if (message.isEndClip()) {
      if (phase !== 'sequence') throw new Error('MIDI Clip End precedes its Start')
      if (words[0] !== 0xf0210000 || words.slice(1).some(word => word !== 0)) throw new Error('Invalid MIDI Clip End marker')
      end = { offset, tick: String(tick) }; continue
    }
    const event = { id: String(offset), offset, section: phase, tick: String(tick), words }
    const tempo = clipTempo(event), meter = clipMeter(event)
    if (phase === 'configuration') {
      if (tempo !== null) {
        if (configurationTempo !== null || configurationPrevious !== 'resolution' || tick !== 0n) throw new Error('Invalid MIDI Clip configuration tempo position')
        configurationTempo = tempo
      }
      if (meter !== null) {
        if (configurationMeter !== null || configurationPrevious !== 'tempo' || tick !== 0n) throw new Error('Invalid MIDI Clip configuration meter position')
        configurationMeter = meter
      }
      configurationPrevious = tempo !== null ? 'tempo' : meter !== null ? 'meter' : 'data'
    }
    events.push(event)
  }
  if (!ppq || !start || !end) throw new Error('Incomplete MIDI Clip resolution, Start or End')
  return { ppq, prefix, events, start, end, configurationTempo, configurationMeter }
}

// The tempo word is unsigned; JZZ 1.9.6 getTempo uses a signed JS bit shift.
export function clipTempo(event) {
  const [word, value] = event.words
  if ((word >>> 28) !== 13 || (word & 0x00ffffff) !== 0x00100000) return null
  if (!value || event.words[2] !== 0 || event.words[3] !== 0) throw new Error('Invalid MIDI Clip Set Tempo')
  return value
}
export function clipMeter(event) {
  const [word, data] = event.words
  if ((word >>> 28) !== 13 || (word & 0x00ffffff) !== 0x00100001) return null
  const numeratorCode = data >>> 24, denominatorPower = data >>> 16 & 255, notated32nds = data >>> 8 & 255
  if ((data & 255) || event.words[2] !== 0 || event.words[3] !== 0) throw new Error('Invalid MIDI Clip Time Signature')
  // Keep raw codes: power zero is explicitly non-standard, and the published
  // eight-bit numerator diagram does not define an encoding for its stated 256.
  return { numeratorCode, denominatorPower, notated32nds }
}

export function importMidiClip(bytes, { name = 'Imported MIDI2 Clip' } = {}) {
  bytes = Buffer.from(bytes); readMidiClip(bytes)
  const document = { schemaVersion: 1, kind: 'midi-clip', name,
    original: { base64: bytes.toString('base64'), sha256: hash(bytes) }, changes: [] }
  validateMidiClip(document)
  return document
}
function originalBytes(document) {
  if (!fields(document, ['schemaVersion', 'kind', 'name', 'original', 'changes']) || document.schemaVersion !== 1
      || document.kind !== 'midi-clip' || typeof document.name !== 'string' || !document.name.trim()
      || !fields(document.original, ['base64', 'sha256']) || typeof document.original.base64 !== 'string'
      || !Array.isArray(document.changes)) throw new Error('Invalid MIDI2 Clip document')
  const bytes = Buffer.from(document.original.base64, 'base64')
  if (bytes.toString('base64') !== document.original.base64 || hash(bytes) !== document.original.sha256) throw new Error('MIDI2 Clip original hash or encoding differs')
  return bytes
}
export function validateMidiClip(document) { midiClipPerformance(document); return document }
export function editMidiClip(document, decisions) {
  const source = midiClipPerformance(document), events = new Map([...source.configuration, ...source.sequence].map(row => [row.id, row]))
  const changes = new Map(document.changes.map(change => [change.id, structuredClone(change)])), seen = new Set()
  for (const decision of decisions) {
    const keys = decision?.kind === 'words' ? ['kind', 'id', 'words'] : decision?.kind === 'time' ? ['kind', 'id', 'tick'] : ['kind', 'id']
    if (!fields(decision, keys) || seen.has(decision.id) || !events.has(decision.id)) throw new Error('Invalid or stale MIDI Clip edit decision')
    seen.add(decision.id)
    const edit = changes.get(decision.id) ?? { id: decision.id }
    switch (decision.kind) {
      case 'words': edit.words = structuredClone(decision.words); break
      case 'time': clipTick(decision.tick); edit.tick = decision.tick; break
      case 'reset-words': delete edit.words; break
      case 'reset-time': delete edit.tick; break
      default: throw new Error('Unknown MIDI Clip edit decision')
    }
    if (Object.keys(edit).length === 1) changes.delete(decision.id)
    else changes.set(decision.id, edit)
  }
  return validateMidiClip({ ...document, changes: [...changes.values()].sort((a, b) => Number(a.id) - Number(b.id)) })
}
export function midiClipNotes(document) {
  return midiClipPerformance(document).sequence.filter(event => (event.words[0] >>> 28) === 4 && (event.words[0] >>> 20 & 15) === 9)
    .map(event => ({ ...event, group: event.words[0] >>> 24 & 15, channel: event.words[0] >>> 16 & 15, ...umpAttackFields(event.words) }))
}
export function editMidiClipAttack(document, id, values) {
  const event = midiClipNotes(document).find(note => note.id === id)
  if (!event) throw new Error('Select a native MIDI2 Clip NoteOn')
  return editMidiClip(document, [{ kind: 'words', id, words: editUmpAttackWords(event.words, values) }])
}
export function midiClipOnset(document, id) {
  const notes = midiClipNotes(document), selected = notes.find(note => note.id === id)
  if (!selected) throw new Error('Select a native MIDI2 Clip NoteOn')
  return notes.filter(note => note.tick === selected.tick && note.group === selected.group && note.channel === selected.channel)
    .sort((a, b) => a.pitch - b.pitch || a.offset - b.offset)
}
export function midiClipHarmony(document, id) { return umpPitchHarmony(midiClipOnset(document, id)) }
export function revoiceMidiClip(document, id, symbol, options) {
  const notes = midiClipOnset(document, id), pitches = chordVoicing(symbol, options)
  if (pitches.length !== notes.length) throw new Error('Voicing must match the exact onset voice count')
  return editMidiClip(document, notes.map((note, index) => ({ kind: 'words', id: note.id,
    words: editUmpAttackWords(note.words, { pitch: pitches[index] * 512 }) })))
}
export function midiClipPerformance(document) {
  const bytes = originalBytes(document), source = readMidiClip(bytes), indexed = new Map(source.events.map(row => [row.id, row])), seen = new Set()
  for (const edit of document.changes) {
    if (!fields(edit, ['id', 'words', 'tick']) || typeof edit.id !== 'string' || seen.has(edit.id)
        || !Object.hasOwn(edit, 'words') && !Object.hasOwn(edit, 'tick')) throw new Error('Invalid or duplicate MIDI Clip edit')
    const event = indexed.get(edit.id)
    if (!event) throw new Error('Unknown original MIDI Clip message identity')
    if (Object.hasOwn(edit, 'words')) {
      if (!Array.isArray(edit.words) || edit.words.length !== event.words.length
          || Array.from(edit.words).some(word => !Number.isInteger(word) || word < 0 || word > 0xffffffff)
          || (edit.words[0] & 0xffffff00) !== (event.words[0] & 0xffffff00)) throw new Error('MIDI Clip edits must preserve message width and address')
      if (edit.words[0] !== event.words[0] && !((event.words[0] >>> 28) === 4 && (event.words[0] >>> 20 & 15) === 9
          && [0, 3].includes(event.words[0] & 255) && (edit.words[0] & 255) === 3)) throw new Error('Only an explicit native NoteOn absolute-pitch override can change its attribute')
    }
    if (Object.hasOwn(edit, 'tick')) {
      if (event.section !== 'sequence') throw new Error('Configuration timing remains part of the original MIDI Clip')
      clipTick(edit.tick)
    }
    indexed.set(edit.id, { ...event, words: edit.words ?? event.words, tick: edit.tick ?? event.tick,
      originalTick: event.tick })
    seen.add(edit.id)
  }
  const configuration = source.events.filter(row => row.section === 'configuration').map(row => indexed.get(row.id))
  const sequence = source.events.filter(row => row.section === 'sequence').map(row => indexed.get(row.id))
    .sort((a, b) => clipTick(a.tick) < clipTick(b.tick) ? -1 : clipTick(a.tick) > clipTick(b.tick) ? 1 : a.offset - b.offset)
  // Validate authored known metadata as well as original metadata.
  for (const row of [...configuration, ...sequence]) { clipTempo(row); clipMeter(row) }
  const endTick = sequence.reduce((end, row) => clipTick(row.tick) > end ? clipTick(row.tick) : end, clipTick(source.end.tick))
  const configurationTempo = configuration.map(clipTempo).find(value => value !== null) ?? null
  const configurationMeter = configuration.map(clipMeter).find(value => value !== null) ?? null
  return { ...source, events: [...configuration, ...sequence], configurationTempo, configurationMeter,
    configuration, sequence, ticks: String(endTick), bytes }
}

// All elapsed times share PPQ as a denominator. Accumulate integer tempo*ticks
// first; callers can round once at their actual output clock boundary.
export function midiClipClock(document, { initialTempo } = {}) {
  if (initialTempo !== undefined && (!Number.isInteger(initialTempo) || initialTempo < 1 || initialTempo > 0xffffffff)) throw new Error('Use an unsigned MIDI2 tempo in 10ns per quarter note')
  const source = midiClipPerformance(document), denominator = String(source.ppq)
  const phase = (events, end, inherited) => {
    let tick = 0n, nanoseconds = 0n, tempo = inherited
    const timed = events.map(event => {
      const next = clipTick(event.tick), distance = next - tick
      if (distance > 0n && tempo === undefined) throw new Error('MIDI Clip needs an explicit tempo before elapsed musical time')
      nanoseconds += distance * BigInt(tempo ?? 0) * 10n; tick = next
      const declared = clipTempo(event); if (declared !== null) tempo = declared
      return { ...event, nanoseconds: { numerator: String(nanoseconds), denominator } }
    })
    const tail = clipTick(end) - tick
    if (tail > 0n && tempo === undefined) throw new Error('MIDI Clip needs an explicit tempo before elapsed musical time')
    nanoseconds += tail * BigInt(tempo ?? 0) * 10n
    return { events: timed, duration: { numerator: String(nanoseconds), denominator }, tempo }
  }
  const configuration = phase(source.configuration, source.start.configurationTicks, initialTempo)
  const sequence = phase(source.sequence, source.ticks, configuration.tempo)
  return { ppq: source.ppq, prefix: source.prefix, configuration, sequence }
}

const wordBytes = words => { const bytes = Buffer.alloc(words.length * 4); words.forEach((word, at) => bytes.writeUInt32BE(word, at * 4)); return bytes }
// Streaming long deltas uses the format's mandated NOOP separators, without
// allocating the complete distance as an in-memory byte array.
export function* midiClipChunks(document) {
  const source = midiClipPerformance(document)
  if (!document.changes.some(change => change.tick !== undefined)) {
    const bytes = Buffer.from(source.bytes)
    for (const row of [...source.configuration, ...source.sequence]) wordBytes(row.words).copy(bytes, row.offset)
    yield bytes; return
  }
  const configurationBytes = Buffer.from(source.bytes.subarray(0, source.start.offset + 16))
  for (const row of source.configuration) wordBytes(row.words).copy(configurationBytes, row.offset)
  yield configurationBytes
  let tick = 0n
  const stamp = function* (distance) {
    while (distance > 0xfffffn) { yield wordBytes([0x004fffff, 0]); distance -= 0xfffffn }
    yield wordBytes([0x00400000 | Number(distance)])
  }
  for (const row of source.sequence) {
    const next = clipTick(row.tick); yield* stamp(next - tick); yield wordBytes(row.words); tick = next
  }
  yield* stamp(clipTick(source.ticks) - tick); yield wordBytes([0xf0210000, 0, 0, 0])
}
