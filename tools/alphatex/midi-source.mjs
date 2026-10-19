import { Chord, Note } from 'tonal'
import { expressionMessage, expressionEvent } from './midi-expression.mjs'

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
const tempoData = data => {
  if (!Array.isArray(data) || data.length !== 3) throw new Error('MIDI tempo needs three bytes')
  data.forEach(byte => integer(byte, 'tempo byte', 0, 255))
  if (!(data[0] * 65536 + data[1] * 256 + data[2])) throw new Error('MIDI tempo must be positive')
  return data
}
export function tempoEvent(event) {
  if (event?.kind !== 'meta' || event.type !== 0x51) return null
  const data = tempoData(event.data), micros = data[0] * 65536 + data[1] * 256 + data[2]
  return { kind: 'tempo', id: event.id, track: event.track, tick: event.tick, micros, value: 60e6 / micros }
}
function tempoBytes(value) {
  if (!Number.isFinite(value) || value <= 0) throw new Error('Tempo BPM must be positive and finite')
  // SMF Set Tempo stores positive 24-bit microseconds per quarter note.
  // Round to the nearest representable microsecond, as JZZ.MIDI.smfBPM does.
  const micros = integer(Math.round(60e6 / value), 'tempo microseconds', 1, 0xffffff)
  return [micros >> 16, (micros >> 8) & 255, micros & 255]
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
  if (source.notation !== undefined) {
    const notation = source.notation
    if (notation?.kind !== 'alphatex' || typeof notation.source !== 'string' || !notation.source.trim()
        || Object.keys(notation).some(key => !['kind', 'source', 'tracks'].includes(key))) throw new Error('Invalid original score notation')
    if (notation.tracks !== undefined && (!Array.isArray(notation.tracks) || !notation.tracks.length
        || new Set(notation.tracks).size !== notation.tracks.length
        || notation.tracks.some(index => !Number.isSafeInteger(index) || index < 0))) throw new Error('Invalid original score track selection')
  }
  const bytes = Buffer.from(source.original, 'base64')
  if (bytes.toString('base64') !== source.original) throw new Error('Invalid canonical MIDI source bytes')
  return parse(bytes)
}
function materialize(source) {
  const parsed = original(source)
  const orders = source.orders === undefined ? [] : source.orders
  if (!Array.isArray(orders)) throw new Error('Invalid MIDI event orders')
  const orderedGroups = new Map()
  for (const order of orders) {
    integer(order?.track, 'ordered MIDI track', 0, parsed.tracks.length - 1); integer(order.tick, 'ordered MIDI tick')
    if (Object.keys(order).some(key => !['track', 'tick', 'events'].includes(key)) || !Array.isArray(order.events)
        || order.events.length < 2 || order.events.some(id => typeof id !== 'string') || new Set(order.events).size !== order.events.length) {
      throw new Error('MIDI order requires a unique event permutation')
    }
    const key = `${order.track}:${order.tick}`
    if (orderedGroups.has(key)) throw new Error('Duplicate MIDI event order')
    orderedGroups.set(key, order)
  }
  const byID = new Map(parsed.tracks.flat().map(event => [event.id, event]))
  const changed = new Map()
  for (const patch of source.changes) {
    const event = byID.get(patch?.id)
    if (!event || !(event.kind === 'channel' || tempoEvent(event)) || changed.has(patch.id)) throw new Error('Invalid or duplicate MIDI source edit')
    if (patch.removed === true) {
      if (Object.keys(patch).some(key => !['id', 'removed'].includes(key))) throw new Error('Removed MIDI event cannot also change')
      changed.set(patch.id, null)
    } else {
      const field = event.kind === 'channel' ? 'bytes' : 'data'
      if (Object.keys(patch).some(key => !['id', 'tick', field].includes(key))) throw new Error('Unknown MIDI source edit field')
      const payload = event.kind === 'channel' ? channelBytes(patch.bytes) : tempoData(patch.data)
      changed.set(patch.id, { ...event, tick: integer(patch.tick, 'edited MIDI tick'), [field]: [...payload] })
    }
  }
  const tracks = parsed.tracks.map(track => track.flatMap(event => changed.has(event.id) ? changed.get(event.id) === null ? [] : [changed.get(event.id)] : [event]))
  const ids = new Set(byID.keys())
  for (const event of source.insertions) {
    const meta = event?.kind === 'meta'
    if (typeof event?.id !== 'string' || !event.id.startsWith('new:') || ids.has(event.id)
        || Object.keys(event).some(key => !(meta ? ['id', 'track', 'tick', 'kind', 'type', 'data'] : ['id', 'track', 'tick', 'bytes']).includes(key))) throw new Error('Invalid inserted MIDI event')
    ids.add(event.id)
    integer(event.track, 'inserted MIDI track', 0, tracks.length - 1)
    if (meta && event.type !== 0x51) throw new Error('Only Set Tempo metadata can be inserted')
    const payload = meta ? { kind: 'meta', data: [...tempoData(event.data)] } : { kind: 'channel', bytes: [...channelBytes(event.bytes)] }
    tracks[event.track].push({ ...event, ...payload, tick: integer(event.tick, 'inserted MIDI tick'), port: 0 })
  }
  // Stable ordering retains original same-tick controller/note order. Inserted
  // events follow existing events at that tick and precede the end marker.
  for (const [trackIndex, track] of tracks.entries()) {
    const end = track.find(event => event.kind === 'meta' && event.type === 0x2f)
    for (const event of track) end.tick = Math.max(end.tick, event.tick)
    track.sort((a, b) => a.tick - b.tick || Number(a === end) - Number(b === end))
    const baselinePorts = new Map(); let baselinePort = 0
    for (const event of track) {
      if (event.kind === 'meta' && event.type === 0x21) baselinePort = event.data[0]
      baselinePorts.set(event.id, baselinePort)
    }
    const ordered = []
    for (let start = 0; start < track.length;) {
      let finish = start + 1
      while (finish < track.length && track[finish].tick === track[start].tick) finish++
      const group = track.slice(start, finish), key = `${trackIndex}:${track[start].tick}`, order = orderedGroups.get(key)
      if (order) {
        const movable = group.filter(event => event !== end), byID = new Map(movable.map(event => [event.id, event]))
        if (order.events.length !== movable.length || order.events.some(id => !byID.has(id))) throw new Error('MIDI order must name every non-end event at its track and tick')
        const reordered = order.events.map(id => byID.get(id))
        const protectedIDs = values => values.filter(event => !expressionEvent(event)).map(event => event.id)
        const expected = protectedIDs(movable), actual = protectedIDs(reordered)
        if (expected.length !== actual.length || expected.some((id, index) => id !== actual[index])) throw new Error('MIDI expression order cannot reorder notes, metadata or SysEx')
        for (const event of reordered) ordered.push(event)
        if (group.includes(end)) ordered.push(end)
        orderedGroups.delete(key)
      } else for (const event of group) ordered.push(event)
      start = finish
    }
    tracks[trackIndex] = ordered
    let port = 0
    for (const event of ordered) {
      if (event.kind === 'meta' && event.type === 0x21) port = event.data[0]
      event.port = port
      if (event.kind === 'channel' && event.port !== baselinePorts.get(event.id)) throw new Error('MIDI event order changes its source port')
      if (event.kind === 'channel' && changed.has(event.id) && event.port !== byID.get(event.id).port) {
        throw new Error('MIDI edit changes the original source port; explicit route edits are not supported')
      }
    }
  }
  if (orderedGroups.size) throw new Error('MIDI order has no matching source events')
  return { ...parsed, tracks }
}
export function importMidiSource(bytes, { name = 'Imported MIDI', notation } = {}) {
  if (!(bytes instanceof Uint8Array)) throw new Error('MIDI import requires bytes')
  const source = { schemaVersion: 1, kind: 'midi-source', name, original: Buffer.from(bytes).toString('base64'), changes: [], insertions: [], ...(notation === undefined ? {} : { notation: structuredClone(notation) }) }
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
function encodeTrack(events) {
  let previous = 0
  const bytes = []
  for (const event of events) {
    bytes.push(Buffer.from(vlq(event.tick - previous))); previous = event.tick
    if (event.kind === 'channel') bytes.push(Buffer.from(event.bytes))
    else if (event.kind === 'meta') bytes.push(Buffer.from([0xff, event.type, ...vlq(event.data.length)]), Buffer.from(event.data))
    else bytes.push(Buffer.from([event.status, ...vlq(event.data.length)]), Buffer.from(event.data))
  }
  return chunk('MTrk', Buffer.concat(bytes))
}
export function exportMidiSource(source) {
  const parsed = materialize(source)
  if (!source.changes.length && !source.insertions.length && !source.orders?.length) return Uint8Array.from(parsed.bytes)
  const touched = new Set([...source.insertions.map(event => event.track), ...(source.orders ?? []).map(order => order.track)])
  for (const patch of source.changes) touched.add(Number(patch.id.split(':')[0]))
  let index = 0
  const parts = parsed.parts.map(part => {
    if (part.type !== 'MTrk') return part.bytes
    const track = index++
    if (!touched.has(track)) return part.bytes
    return encodeTrack(parsed.tracks[track])
  })
  const smf = Buffer.concat(parts)
  if (!parsed.container) return Uint8Array.from(smf)
  const wrapped = Buffer.concat([Buffer.from('RMID'), ...parsed.container.map(part => part.type === 'data' ? chunk('data', smf, true, true) : part.bytes)])
  const header = Buffer.alloc(8); header.write('RIFF'); header.writeUInt32LE(integer(wrapped.length, 'RIFF MIDI length', 0, 0xffffffff), 4)
  return Uint8Array.from(Buffer.concat([header, wrapped]))
}
// A selected performance for synchronous PPQ hosts. Original bytes and
// provenance remain in the document and exportMidiSource().
export function exportMidiSourcePattern(source, options = {}) {
  const parsed = materialize(source), performance = midiSourcePattern(source, options)
  let tracks = parsed.format === 2 ? [parsed.tracks[performance.pattern]] : parsed.tracks
  let division = parsed.timing.ppq
  if (parsed.timing.kind === 'smpte') {
    const timing = parsed.timing
    // One quarter per second (1001/1000 for drop-frame) preserves every
    // source tick. SMPTE ignores the source tempo events.
    division = (timing.frameCode === 29 ? 30 : timing.frameCode) * timing.ticksPerFrame
    const tempo = timing.frameCode === 29 ? 1001000 : 1000000
    tracks = tracks.map(events => events.filter(event => event.kind !== 'meta' || event.type !== 0x51))
    tracks = [[{ tick: 0, kind: 'meta', type: 0x51, data: [tempo >> 16, (tempo >> 8) & 255, tempo & 255] },
      { tick: performance.ticks, kind: 'meta', type: 0x2f, data: [] }], ...tracks]
  }
  const header = Buffer.alloc(6)
  header.writeUInt16BE(tracks.length === 1 ? 0 : 1)
  header.writeUInt16BE(tracks.length, 2); header.writeUInt16BE(division, 4)
  return Uint8Array.from(Buffer.concat([chunk('MThd', header), ...tracks.map(encodeTrack)]))
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
    seconds = parsed.timing.kind === 'ppq' ? seconds + (event.tick - tick) / parsed.timing.ppq * micros / 1e6
      : event.tick * parsed.timing.denominator / parsed.timing.numerator / parsed.timing.ticksPerFrame
    event.seconds = seconds; tick = event.tick
    if (event.kind === 'meta' && event.type === 0x51) micros = tempoEvent(event).micros
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
  const { next, insert, place, finish } = sourcePatch(source)
  const events = new Map(performance.events.map(event => [event.id, event]))
  const targets = new Map()
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
  finish(); exportMidiSource(next)
  const pairs = new Map(midiSourcePattern(next, { pattern }).notes.map(note => [note.id, note]))
  for (const [on, expected] of targets) {
    if (expected !== null && (pairs.get(on)?.off !== expected.off || pairs.get(on)?.port !== expected.port)) {
      throw new Error('MIDI edit changes note-off pairing or source port')
    }
  }
  return next
}

function sourcePatch(source) {
  const next = structuredClone(source), used = new Set(next.insertions.map(event => event.id))
  let number = 1
  const detach = id => {
    if (!next.orders) return
    next.orders = next.orders.map(order => ({ ...order, events: order.events.filter(event => event !== id) })).filter(order => order.events.length > 1)
    if (!next.orders.length) delete next.orders
  }
  const append = (id, track, tick) => {
    const order = next.orders?.find(order => order.track === track && order.tick === tick)
    if (order) order.events.push(id)
  }
  const add = (track, tick, payload) => {
    while (used.has(`new:${number}`)) number++
    const id = `new:${number++}`; used.add(id)
    next.insertions.push({ id, track, tick, ...payload }); append(id, track, tick); return id
  }
  const insert = (track, tick, bytes) => add(track, tick, { bytes })
  const insertTempo = (track, tick, data) => add(track, tick, { kind: 'meta', type: 0x51, data })
  const place = (event, value) => {
    if (value.removed || value.tick !== event.tick) {
      detach(event.id)
      if (!value.removed) append(event.id, event.track, value.tick)
    }
    const added = next.insertions.findIndex(item => item.id === event.id)
    if (added >= 0) {
      if (value.removed) next.insertions.splice(added, 1)
      else next.insertions[added] = { id: event.id, track: event.track,
        ...(event.kind === 'meta' ? { kind: 'meta', type: event.type } : {}), ...value }
    } else {
      next.changes = next.changes.filter(item => item.id !== event.id)
      next.changes.push({ id: event.id, ...value })
    }
  }
  const finish = () => {
    if (!next.orders) return
    // Retimed/inserted notes and metadata retain their natural mutual order.
    // Expressions keep the explicit slots in the reconciled permutation.
    const natural = materialize({ ...next, orders: undefined })
    for (const order of next.orders) {
      const group = natural.tracks[order.track].filter(event => event.tick === order.tick && !(event.kind === 'meta' && event.type === 0x2f))
      const byID = new Map(group.map(event => [event.id, event]))
      const protectedIDs = group.filter(event => !expressionEvent(event)).map(event => event.id)
      let index = 0
      order.events = order.events.map(id => expressionEvent(byID.get(id)) ? id : protectedIDs[index++])
    }
  }
  return { next, insert, insertTempo, place, finish }
}

export function editMidiSourceTempos(source, edits, { pattern } = {}) {
  const performance = midiSourcePattern(source, { pattern }), events = new Map(performance.events.map(event => [event.id, event]))
  const { next, insertTempo, place, finish } = sourcePatch(source), used = new Set()
  for (const edit of edits) {
    if (edit.kind === 'insert') {
      const track = performance.format === 2 ? performance.pattern : 0
      insertTempo(track, integer(edit.tick, 'tempo tick'), tempoBytes(edit.value))
      continue
    }
    const event = events.get(edit.id), value = tempoEvent(event)
    if (!value || used.has(edit.id)) throw new Error('Select a unique tempo event in this pattern')
    used.add(edit.id)
    if (edit.kind === 'remove') place(event, { removed: true })
    else if (edit.kind === 'change') place(event, { tick: integer(edit.tick ?? event.tick, 'tempo tick'), data: edit.value === undefined ? [...event.data] : tempoBytes(edit.value) })
    else throw new Error('Unknown MIDI tempo edit')
  }
  finish(); exportMidiSource(next); midiSourcePattern(next, { pattern })
  return next
}

// A complete same-tick permutation has no dangling anchors or cycles. Edits
// reconcile membership; only this explicit operation changes relative order.
export function orderMidiSourceExpression(source, { id, before }, { pattern } = {}) {
  const performance = midiSourcePattern(source, { pattern }), selected = performance.events.find(event => event.id === id)
  if (!expressionEvent(selected)) throw new Error('Select an expression event in this MIDI pattern')
  const group = performance.events.filter(event => event.track === selected.track && event.tick === selected.tick && !(event.kind === 'meta' && event.type === 0x2f))
  const next = structuredClone(source), remaining = (next.orders ?? []).filter(order => order.track !== selected.track || order.tick !== selected.tick)
  if (before !== null) {
    const target = group.find(event => event.id === before)
    if (!target || target.id === id) throw new Error('Choose another non-end event at the same track and tick')
    const events = group.filter(event => event.id !== id).map(event => event.id)
    events.splice(events.indexOf(before), 0, id)
    remaining.push({ track: selected.track, tick: selected.tick, events })
  }
  if (remaining.length) next.orders = remaining
  else delete next.orders
  exportMidiSource(next)
  return next
}

export function editMidiSourceExpressions(source, edits, { pattern } = {}) {
  const performance = midiSourcePattern(source, { pattern }), info = midiSourceInfo(source)
  const events = new Map(performance.events.map(event => [event.id, event]))
  const { next, insert, place, finish } = sourcePatch(source), targets = new Map()
  for (const edit of edits) {
    const { id, kind } = edit
    if (kind === 'insert') {
      const track = integer(edit.track, 'MIDI insertion track', 0, info.tracks.length - 1)
      if (info.format === 2 && track !== performance.pattern) throw new Error('Insert into the selected MIDI pattern')
      insert(track, integer(edit.tick, 'expression tick'), expressionMessage(edit.message)); continue
    }
    const event = events.get(id), message = expressionEvent(event)
    if (!message || targets.has(id)) throw new Error('Select a unique expression event in this pattern')
    if (kind === 'remove') { place(event, { removed: true }); targets.set(id, null) }
    else if (kind === 'change') {
      place(event, { tick: integer(edit.tick ?? event.tick, 'expression tick'), bytes: expressionMessage(edit.message ?? message) })
      targets.set(id, event.port)
    } else throw new Error('Unknown MIDI expression edit')
  }
  finish(); exportMidiSource(next)
  const changed = new Map(midiSourcePattern(next, { pattern }).events.map(event => [event.id, event]))
  for (const [id, port] of targets) {
    if (port !== null && changed.get(id)?.port !== port) {
      throw new Error('MIDI expression move changes its source port')
    }
  }
  return next
}
