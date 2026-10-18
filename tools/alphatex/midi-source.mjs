import { Chord, Note } from 'tonal'

// The original file is immutable provenance. Edits address source events, rather
// than reducing a MIDI performance to the phrase editor's note-only schema.
const MAX_DELTA = 0x0fffffff
const integer = (value, name, min = 0, max = Number.MAX_SAFE_INTEGER) => {
  if (!Number.isSafeInteger(value) || value < min || value > max) throw new Error(`Invalid ${name}`)
  return value
}
const channelBytes = bytes => {
  if (!Array.isArray(bytes) || !bytes.length) throw new Error('Invalid MIDI channel message')
  bytes.forEach(byte => integer(byte, 'MIDI byte', 0, 255))
  const status = bytes[0]
  if (status < 0x80 || status >= 0xf0 || bytes.length !== ([0xc0, 0xd0].includes(status & 0xf0) ? 2 : 3)
      || bytes.slice(1).some(byte => byte >= 128)) throw new Error('Invalid MIDI channel message')
  return bytes
}
const tag = (bytes, offset) => bytes.toString('latin1', offset, offset + 4)
function chunks(bytes, start, end, littleEndian = false, padded = false) {
  const result = []
  let offset = start
  while (offset < end) {
    if (offset + 8 > end) throw new Error('Truncated MIDI container chunk header')
    const length = littleEndian ? bytes.readUInt32LE(offset + 4) : bytes.readUInt32BE(offset + 4)
    const finish = offset + 8 + length, next = finish + (padded ? length % 2 : 0)
    if (next > end) throw new Error('Truncated MIDI container chunk')
    result.push({ type: tag(bytes, offset), bytes: bytes.subarray(offset, next), data: bytes.subarray(offset + 8, finish) })
    offset = next
  }
  return result
}
function trackEvents(data, track) {
  let position = 0, tick = 0, running = null, ended = false, port = 0
  const events = []
  function byte() {
    if (position >= data.length) throw new Error('Truncated MIDI event')
    return data[position++]
  }
  function variable() {
    let value = 0
    for (let n = 0; n < 4; n++) {
      const next = byte(); value = value * 128 + (next & 127)
      if (next < 128) return value
    }
    throw new Error('MIDI variable-length value exceeds four bytes')
  }
  function payload(length) {
    if (position + length > data.length) throw new Error('Truncated MIDI payload')
    const value = [...data.subarray(position, position + length)]; position += length
    return value
  }
  while (position < data.length) {
    if (ended) throw new Error('Events follow MIDI end-of-track')
    tick += variable(); integer(tick, 'MIDI absolute tick')
    let status = byte(), event
    if (status === 0xff) {
      running = null
      const type = byte()
      if (type >= 128) throw new Error('Invalid MIDI meta type')
      const bytes = payload(variable())
      event = { kind: 'meta', type, data: bytes }
      if (type === 0x2f) {
        if (bytes.length) throw new Error('Invalid MIDI end-of-track')
        ended = true
      }
      if (type === 0x21) {
        if (bytes.length !== 1 || bytes[0] >= 128) throw new Error('Invalid MIDI port meta event')
        port = bytes[0]
      }
    } else if (status === 0xf0 || status === 0xf7) {
      running = null
      event = { kind: 'sysex', status, data: payload(variable()) }
    } else {
      if (status < 128) {
        if (running === null) throw new Error('MIDI data has no running status')
        position--; status = running
      }
      if (status < 0x80 || status >= 0xf0) throw new Error('Invalid channel status in MIDI track')
      running = status
      const bytes = channelBytes([status, ...payload([0xc0, 0xd0].includes(status & 0xf0) ? 1 : 2)])
      event = { kind: 'channel', bytes }
    }
    events.push({ id: `${track}:${events.length}`, track, tick, port, ...event })
  }
  if (!ended) throw new Error('MIDI track has no end-of-track')
  return events
}
function parse(bytes) {
  let container = null, data = bytes
  if (tag(bytes, 0) === 'RIFF') {
    if (bytes.length < 12 || bytes.readUInt32LE(4) !== bytes.length - 8 || tag(bytes, 8) !== 'RMID') throw new Error('Invalid RIFF MIDI container')
    container = chunks(bytes, 12, bytes.length, true, true)
    const sources = container.filter(chunk => chunk.type === 'data')
    if (sources.length !== 1) throw new Error('RIFF MIDI requires one data chunk')
    data = sources[0].data
  }
  const parts = chunks(data, 0, data.length)
  const header = parts[0]
  if (header?.type !== 'MThd' || header.data.length < 6) throw new Error('Invalid MIDI header')
  const format = header.data.readUInt16BE(0), count = header.data.readUInt16BE(2), division = header.data.readUInt16BE(4)
  if (![0, 1, 2].includes(format) || !count || format === 0 && count !== 1) throw new Error('Invalid MIDI format or track count')
  let timing
  if (division & 0x8000) {
    const fps = 256 - (division >> 8), ticksPerFrame = division & 255
    if (![24, 25, 29, 30].includes(fps) || !ticksPerFrame) throw new Error('Invalid MIDI SMPTE division')
    timing = { kind: 'smpte', frameCode: fps, numerator: fps === 29 ? 30000 : fps, denominator: fps === 29 ? 1001 : 1, ticksPerFrame }
  } else {
    if (!division) throw new Error('Invalid MIDI PPQ division')
    timing = { kind: 'ppq', ppq: division }
  }
  const tracks = []
  for (const chunk of parts.slice(1)) if (chunk.type === 'MTrk') tracks.push(trackEvents(chunk.data, tracks.length))
  if (tracks.length !== count) throw new Error('MIDI header and actual track counts differ')
  return { bytes, container, parts, format, timing, tracks }
}
function original(source) {
  if (source?.schemaVersion !== 1 || source.kind !== 'midi-source' || typeof source.name !== 'string' || !source.name.trim()
      || typeof source.original !== 'string' || !Array.isArray(source.changes) || !Array.isArray(source.insertions)) throw new Error('Invalid MIDI source document')
  const bytes = Buffer.from(source.original, 'base64')
  if (bytes.toString('base64') !== source.original) throw new Error('Invalid canonical MIDI source bytes')
  return parse(bytes)
}
function materialize(source) {
  const parsed = original(source)
  const byID = new Map(parsed.tracks.flat().map(event => [event.id, event]))
  const changed = new Map()
  for (const patch of source.changes) {
    const event = byID.get(patch?.id)
    if (!event || event.kind !== 'channel' || changed.has(patch.id)) throw new Error('Invalid or duplicate MIDI source edit')
    if (patch.removed === true) {
      if (Object.keys(patch).some(key => !['id', 'removed'].includes(key))) throw new Error('Removed MIDI event cannot also change')
      changed.set(patch.id, null)
    } else {
      if (Object.keys(patch).some(key => !['id', 'tick', 'bytes'].includes(key))) throw new Error('Unknown MIDI source edit field')
      changed.set(patch.id, { ...event, tick: integer(patch.tick, 'edited MIDI tick'), bytes: [...channelBytes(patch.bytes)] })
    }
  }
  const tracks = parsed.tracks.map(track => track.flatMap(event => changed.has(event.id) ? changed.get(event.id) === null ? [] : [changed.get(event.id)] : [event]))
  const ids = new Set(byID.keys())
  for (const event of source.insertions) {
    if (typeof event?.id !== 'string' || !event.id.startsWith('new:') || ids.has(event.id)
        || Object.keys(event).some(key => !['id', 'track', 'tick', 'bytes'].includes(key))) throw new Error('Invalid inserted MIDI event')
    ids.add(event.id)
    integer(event.track, 'inserted MIDI track', 0, tracks.length - 1)
    tracks[event.track].push({ ...event, tick: integer(event.tick, 'inserted MIDI tick'), kind: 'channel', bytes: [...channelBytes(event.bytes)], port: 0 })
  }
  // Stable ordering retains original same-tick controller/note order. Inserted
  // events follow existing events at that tick and precede the end marker.
  for (const track of tracks) {
    const end = track.find(event => event.kind === 'meta' && event.type === 0x2f)
    for (const event of track) end.tick = Math.max(end.tick, event.tick)
    track.sort((a, b) => a.tick - b.tick || Number(a === end) - Number(b === end))
    let port = 0
    for (const event of track) {
      if (event.kind === 'meta' && event.type === 0x21) port = event.data[0]
      event.port = port
      if (changed.has(event.id) && event.port !== byID.get(event.id).port) {
        throw new Error('MIDI edit changes the original source port; explicit route edits are not supported')
      }
    }
  }
  return { ...parsed, tracks }
}
export function importMidiSource(bytes, { name = 'Imported MIDI' } = {}) {
  if (!(bytes instanceof Uint8Array)) throw new Error('MIDI import requires bytes')
  const source = { schemaVersion: 1, kind: 'midi-source', name, original: Buffer.from(bytes).toString('base64'), changes: [], insertions: [] }
  materialize(source)
  return source
}
export function validateMidiSource(source) { materialize(source); return source }
function vlq(value) {
  integer(value, 'MIDI delta', 0, MAX_DELTA)
  const bytes = [value & 127]
  while ((value = Math.floor(value / 128))) bytes.unshift((value & 127) | 128)
  return bytes
}
function chunk(type, data, littleEndian = false, padded = false) {
  const header = Buffer.alloc(8)
  header.write(type, 0, 4, 'latin1')
  integer(data.length, 'MIDI chunk length', 0, 0xffffffff)
  if (littleEndian) header.writeUInt32LE(data.length, 4)
  else header.writeUInt32BE(data.length, 4)
  return Buffer.concat([header, data, ...(padded && data.length % 2 ? [Buffer.from([0])] : [])])
}
export function exportMidiSource(source) {
  const parsed = materialize(source)
  if (!source.changes.length && !source.insertions.length) return Uint8Array.from(parsed.bytes)
  const touched = new Set(source.insertions.map(event => event.track))
  for (const patch of source.changes) touched.add(Number(patch.id.split(':')[0]))
  let index = 0
  const parts = parsed.parts.map(part => {
    if (part.type !== 'MTrk') return part.bytes
    const track = index++
    if (!touched.has(track)) return part.bytes
    let previous = 0
    const bytes = []
    for (const event of parsed.tracks[track]) {
      bytes.push(Buffer.from(vlq(event.tick - previous))); previous = event.tick
      if (event.kind === 'channel') bytes.push(Buffer.from(event.bytes))
      else if (event.kind === 'meta') bytes.push(Buffer.from([0xff, event.type, ...vlq(event.data.length)]), Buffer.from(event.data))
      else bytes.push(Buffer.from([event.status, ...vlq(event.data.length)]), Buffer.from(event.data))
    }
    return chunk('MTrk', Buffer.concat(bytes))
  })
  const smf = Buffer.concat(parts)
  if (!parsed.container) return Uint8Array.from(smf)
  const wrapped = Buffer.concat([Buffer.from('RMID'), ...parsed.container.map(part => part.type === 'data' ? chunk('data', smf, true, true) : part.bytes)])
  const header = Buffer.alloc(8); header.write('RIFF'); header.writeUInt32LE(integer(wrapped.length, 'RIFF MIDI length', 0, 0xffffffff), 4)
  return Uint8Array.from(Buffer.concat([header, wrapped]))
}
export function midiSourcePattern(source, { pattern } = {}) {
  const parsed = materialize(source)
  if (parsed.format === 2 && parsed.tracks.length > 1 && pattern === undefined) throw new Error('Select a format-2 MIDI pattern explicitly')
  const selected = pattern ?? 0
  integer(selected, 'MIDI pattern', 0, parsed.format === 2 ? parsed.tracks.length - 1 : 0)
  const events = (parsed.format === 2 ? parsed.tracks[selected] : parsed.tracks.flat())
    .sort((a, b) => a.tick - b.tick || a.track - b.track)
  let tick = 0, seconds = 0, micros = 500000
  const diagnostics = [], active = new Map(), notes = []
  for (const event of events) {
    seconds += parsed.timing.kind === 'ppq' ? (event.tick - tick) / parsed.timing.ppq * micros / 1e6
      : (event.tick - tick) * parsed.timing.denominator / parsed.timing.numerator / parsed.timing.ticksPerFrame
    event.seconds = seconds; tick = event.tick
    if (event.kind === 'meta' && event.type === 0x51) {
      if (event.data.length !== 3 || !(event.data[0] * 65536 + event.data[1] * 256 + event.data[2])) throw new Error('Invalid MIDI tempo event')
      micros = event.data[0] * 65536 + event.data[1] * 256 + event.data[2]
    }
    if (event.kind !== 'channel') continue
    const [status, key, velocity] = event.bytes, type = status & 0xf0, channel = status & 15
    const identity = `${event.port}:${channel}:${key}`
    if (type === 0x90 && velocity > 0) {
      const held = active.get(identity) ?? []
      if (held.length) diagnostics.push({ kind: 'overlapping-key', event: event.id })
      held.push(event); active.set(identity, held)
    } else if (type === 0x80 || type === 0x90 && velocity === 0) {
      const held = active.get(identity), on = held?.shift()
      if (!on) { diagnostics.push({ kind: 'unmatched-note-off', event: event.id }); continue }
      notes.push({ id: on.id, off: event.id, track: on.track, port: on.port, channel, pitch: key, velocity: on.bytes[2],
        start: on.tick, duration: event.tick - on.tick, seconds: on.seconds, durationSeconds: event.seconds - on.seconds })
    }
  }
  for (const held of active.values()) for (const event of held) diagnostics.push({ kind: 'unclosed-note', event: event.id })
  return { format: parsed.format, timing: parsed.timing, patterns: parsed.format === 2 ? parsed.tracks.length : 1,
    pattern: selected, events, notes, diagnostics, ticks: tick, seconds }
}
export function midiSourceHarmony(source, seconds, options = {}) {
  if (!Number.isFinite(seconds) || seconds < 0) throw new Error('Invalid MIDI analysis position')
  const { notes } = midiSourcePattern(source, options)
  const pitches = [...new Set(notes.filter(note => note.seconds <= seconds && seconds < note.seconds + note.durationSeconds)
    .filter(note => options.channel === undefined || note.channel === options.channel).map(note => note.pitch))].sort((a, b) => a - b)
  return { pitches, notes: pitches.map(Note.fromMidi), candidates: Chord.detect(pitches.map(Note.fromMidi)) }
}
export function midiSourceInfo(source) {
  const parsed = materialize(source)
  return { format: parsed.format, timing: parsed.timing, patterns: parsed.format === 2 ? parsed.tracks.length : 1,
    tracks: parsed.tracks.map((events, index) => ({ index,
      name: Buffer.from(events.find(event => event.kind === 'meta' && event.type === 3)?.data ?? []).toString('utf8') || `Track ${index + 1}` })) }
}
export function editMidiSourceNote(source, edit = {}) { return editMidiSourceNotes(source, [edit], { pattern: edit.pattern }) }
export function editMidiSourceNotes(source, edits, { pattern } = {}) {
  const performance = midiSourcePattern(source, { pattern }), info = midiSourceInfo(source)
  const notes = new Map(performance.notes.map(note => [note.id, note]))
  const next = structuredClone(source)
  const events = new Map(performance.events.map(event => [event.id, event]))
  const used = new Set(next.insertions.map(event => event.id)), targets = new Map()
  let number = 1
  const insert = (track, tick, bytes) => {
    while (used.has(`new:${number}`)) number++
    const id = `new:${number++}`; used.add(id)
    next.insertions.push({ id, track, tick, bytes }); return id
  }
  const place = (event, value) => {
    const added = next.insertions.findIndex(item => item.id === event.id)
    if (added >= 0) {
      if (value.removed) next.insertions.splice(added, 1)
      else next.insertions[added] = { id: event.id, track: event.track, ...value }
    } else {
      next.changes = next.changes.filter(item => item.id !== event.id)
      next.changes.push({ id: event.id, ...value })
    }
  }
  for (const edit of edits) {
    const { id, kind = 'change', pitch, velocity, start, duration } = edit
    if (kind === 'insert') {
      const track = integer(edit.track, 'MIDI insertion track', 0, info.tracks.length - 1)
      if (info.format === 2 && track !== performance.pattern) throw new Error('Insert into the selected MIDI pattern')
      const channel = integer(edit.channel, 'MIDI insertion channel', 0, 15)
      const key = integer(pitch, 'MIDI note pitch', 0, 127), vel = integer(velocity, 'MIDI note velocity', 1, 127)
      const at = integer(start, 'MIDI note start'), end = integer(at + integer(duration, 'MIDI note duration', 1), 'MIDI note end')
      const on = insert(track, at, [0x90 | channel, key, vel]), off = insert(track, end, [0x80 | channel, key, 0])
      // Insertions follow existing same-tick metadata, so the active port at
      // their start is the source route they must retain through their note-off.
      const port = performance.events.filter(event => event.track === track && event.tick <= at
        && event.kind === 'meta' && event.type === 0x21).at(-1)?.data[0] ?? 0
      targets.set(on, { off, port }); continue
    }
    const note = notes.get(id)
    if (!note || targets.has(id)) throw new Error('No unique paired MIDI note selected')
    const on = events.get(note.id), off = events.get(note.off)
    if (kind === 'remove') { place(on, { removed: true }); place(off, { removed: true }); targets.set(id, null) }
    else if (kind === 'change') {
      const key = integer(pitch ?? note.pitch, 'MIDI note pitch', 0, 127), vel = integer(velocity ?? note.velocity, 'MIDI note velocity', 1, 127)
      const at = integer(start ?? note.start, 'MIDI note start'), length = integer(duration ?? note.duration, 'MIDI note duration', 0)
      const end = integer(at + length, 'MIDI note end')
      place(on, { tick: at, bytes: [on.bytes[0], key, vel] })
      place(off, { tick: end, bytes: [off.bytes[0], key, off.bytes[2]] })
      targets.set(id, { off: note.off, port: note.port })
    } else throw new Error('Unknown MIDI note edit')
  }
  // Reject unrepresentable deltas and edits that would silently pair the changed
  // key with a different source note-off or move it across a source port change.
  exportMidiSource(next)
  const pairs = new Map(midiSourcePattern(next, { pattern }).notes.map(note => [note.id, note]))
  for (const [on, expected] of targets) {
    if (expected !== null && (pairs.get(on)?.off !== expected.off || pairs.get(on)?.port !== expected.port)) {
      throw new Error('MIDI edit changes note-off pairing or source port')
    }
  }
  return next
}
