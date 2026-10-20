import { Chord, Note, Interval, Voicing, VoicingDictionary, VoiceLeading } from 'tonal'
import { validateSound } from './project-sound.mjs'

// Quarter-note ticks are the document authority. Wall time belongs to transport.
export const PPQ = 960 // alphaSynth's native quarter-note resolution
export const GM_DRUM_CHANNEL = 9 // General MIDI channel numbers on the wire are zero-based.
const MAX_SMF_DELTA = 0x0fffffff // SMF variable-length delta time has at most four 7-bit bytes.
const MELODIC_CHANNELS = Array.from({ length: 16 }, (_, i) => i).filter(channel => channel !== GM_DRUM_CHANNEL)
const int = (value, name, low = 0, high = Number.MAX_SAFE_INTEGER) => {
  if (!Number.isSafeInteger(value) || value < low || value > high) throw new Error(`Invalid ${name}`)
  return value
}
const text = (value, name) => {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`Invalid ${name}`)
  return value
}
export function pitch(value) {
  const numeric = typeof value === 'string' && value.trim() !== '' ? Number(value) : NaN
  const midi = typeof value === 'number' ? value : Number.isFinite(numeric) ? numeric : Note.midi(value)
  return int(midi, 'pitch (use C4 or MIDI 0–127)', 0, 127)
}
export function beats(value) {
  const ticks = Number(value) * PPQ
  return int(ticks, 'beat position (must resolve to whole ticks)')
}
export function validateProject(project) {
  if (project?.sound !== undefined) validateSound(project.sound)
  if (project?.schemaVersion !== 1 || project.ppq !== PPQ) throw new Error('Unsupported sequencer document')
  text(project.title, 'title')
  int(project.tempo, 'tempo', 4, 60000000) // SMF's 24-bit microseconds/quarter field, minimum 1µs
  // The conductor track ends at document length after its tick-zero metadata.
  int(project.length, 'length (SMF delta-time range)', 1, MAX_SMF_DELTA)
  if (!Array.isArray(project.meter) || project.meter.length !== 2) throw new Error('Invalid meter')
  int(project.meter[0], 'meter numerator', 1, 255)
  if (![1, 2, 4, 8, 16, 32, 64, 128].includes(project.meter[1])) throw new Error('Invalid meter denominator')
  int(project.loop?.start, 'loop start', 0, project.length - 1)
  int(project.loop?.end, 'loop end', project.loop.start + 1, project.length)
  if (!Array.isArray(project.tracks) || !project.tracks.length) throw new Error('A project needs a track')
  const ids = new Set(), channels = new Set()
  for (const track of project.tracks) {
    text(track.id, 'track id'); text(track.name, 'track name')
    if (ids.has(track.id)) throw new Error('Duplicate track id')
    ids.add(track.id)
    int(track.channel, 'MIDI channel', 0, 15); int(track.program, 'program', 0, 127)
    int(track.level, 'track level', 0, 127); int(track.pan, 'track pan', 0, 127)
    if (channels.has(track.channel)) throw new Error('Tracks need separate MIDI channels to retain independent programs')
    channels.add(track.channel)
    if (typeof track.muted !== 'boolean' || typeof track.solo !== 'boolean') throw new Error('Invalid track audibility')
    if (!Array.isArray(track.notes)) throw new Error('Invalid notes')
    const noteIds = new Set()
    for (const note of track.notes) {
      text(note.id, 'note id')
      if (noteIds.has(note.id)) throw new Error('Duplicate note id')
      noteIds.add(note.id)
      // Note names belong to edit input. Persisted documents use one numeric key
      // identity for overlap checks, harmony, transposition and MIDI serialization.
      int(note.pitch, 'note pitch', 0, 127); int(note.start, 'note start', 0, project.length - 1)
      int(note.duration, 'note duration', 1, project.length - note.start)
      int(note.velocity, 'note velocity', 1, 127)
    }
    // A MIDI channel cannot distinguish overlapping instances of the same key.
    const notes = [...track.notes].sort((a, b) => a.pitch - b.pitch || a.start - b.start)
    for (let i = 1; i < notes.length; i++) {
      if (notes[i].pitch === notes[i - 1].pitch && notes[i].start < notes[i - 1].start + notes[i - 1].duration) {
        throw new Error('Overlapping notes of the same pitch on one track')
      }
    }
  }
  return project
}
export function newProject() {
  return { schemaVersion: 1, ppq: PPQ, title: 'Phrase laboratory', tempo: 100,
    meter: [4, 4], length: 16 * PPQ, loop: { start: 0, end: 16 * PPQ },
    tracks: [{ id: 'track-1', name: 'Piano', channel: 0, program: 0, level: 100, pan: 64, muted: false, solo: false, notes: [] }] }
}
function uniqueId(prefix, existing) {
  const used = new Set(existing.map(item => item.id))
  let i = 1
  while (used.has(`${prefix}-${i}`)) i++
  return `${prefix}-${i}`
}
export function activeTracks(project) {
  const solo = project.tracks.some(track => track.solo)
  return project.tracks.filter(track => !track.muted && (!solo || track.solo))
}
export function harmonyAt(project, tick, { all = false } = {}) {
  const notes = (all ? project.tracks : activeTracks(project)).filter(track => track.channel !== GM_DRUM_CHANNEL).flatMap(track => track.notes)
    .filter(note => note.start <= tick && tick < note.start + note.duration)
  const pitches = [...new Set(notes.map(note => note.pitch))].sort((a, b) => a - b)
  return { pitches, notes: pitches.map(Note.fromMidi), candidates: Chord.detect(pitches.map(Note.fromMidi)) }
}

// Sweep exact key intervals, without grouping nearby attacks or inferring pedal
// durations. Counts retain shared keys until their last overlapping voice ends.
export function harmonyTimeline(notes, end, { cancelled = () => false } = {}) {
  int(end, 'analysis end')
  const boundaries = new Map([[0, { deltas: [], points: [] }], [end, { deltas: [], points: [] }]])
  const edge = tick => {
    if (!boundaries.has(tick)) boundaries.set(tick, { deltas: [], points: [] })
    return boundaries.get(tick)
  }
  const check = () => { if (cancelled()) throw new Error('Harmony analysis cancelled') }
  for (const note of notes) {
    check()
    int(note.pitch, 'analysis pitch', 0, 127)
    int(note.start, 'analysis note start', 0, end)
    int(note.duration, 'analysis note duration', 0, end - note.start)
    if (note.duration === 0) edge(note.start).points.push(note.pitch)
    else {
      edge(note.start).deltas.push([note.pitch, 1])
      edge(note.start + note.duration).deltas.push([note.pitch, -1])
    }
  }
  const ticks = [...boundaries.keys()].sort((a, b) => a - b), held = new Map(), rows = []
  const row = (kind, start, finish, pitches) => {
    const names = pitches.map(Note.fromMidi)
    return { kind, start, end: finish, pitches, notes: names, candidates: Chord.detect(names) }
  }
  for (const [index, tick] of ticks.entries()) {
    check()
    const { deltas, points } = boundaries.get(tick)
    for (const [key, delta] of deltas) {
      const count = (held.get(key) ?? 0) + delta
      if (count === 0) held.delete(key)
      else held.set(key, count)
    }
    const pitches = [...held.keys()].sort((a, b) => a - b)
    if (points.length) rows.push(row('point', tick, tick, [...new Set([...pitches, ...points])].sort((a, b) => a - b)))
    const finish = ticks[index + 1]
    if (finish === undefined) continue
    const previous = rows.at(-1)
    if (previous?.kind === 'span' && previous.end === tick && previous.pitches.length === pitches.length
      && previous.pitches.every((key, i) => key === pitches[i])) previous.end = finish
    else rows.push(row('span', tick, finish, pitches))
  }
  return rows
}
function chordShape(intervals, mode, inversion) {
  if (!['close', 'drop2'].includes(mode)) throw new Error('Voicing must be close, drop2 or rootless')
  const notes = [...intervals]
  for (let i = 0; i < inversion; i++) {
    let raised = notes.shift()
    while (raised <= notes[notes.length - 1]) raised += 12
    notes.push(raised)
  }
  if (mode === 'drop2') {
    if (notes.length < 4) throw new Error('Drop 2 needs at least four voices')
    notes[notes.length - 2] -= 12
  }
  return notes.sort((a, b) => a - b)
}

// Tonal supplies chord spelling/intervals and rootless dictionaries. The explicit
// register and inversion remain the musician's choices; candidates are not verdicts.
export function chordVoicing(symbol, { mode = 'close', octave = 4, inversion = 0, previous = [] } = {}) {
  const chord = Chord.get(symbol)
  if (chord.empty || !chord.tonic) throw new Error(`Unknown chord: ${symbol}`)
  int(octave, 'octave', -1, 9)
  int(inversion, 'inversion', 0, chord.intervals.length - 1)
  let notes
  if (mode === 'rootless') {
    if (chord.bass) throw new Error('Rootless voicing does not support an explicit slash-chord bass')
    if (inversion !== 0) throw new Error('Rootless voicing does not support an explicit inversion')
    const low = pitch(`${chord.tonic}${octave}`), high = Math.min(127, low + 24)
    const candidates = Voicing.search(symbol, [Note.fromMidi(low), Note.fromMidi(high)], VoicingDictionary.lefthand)
    if (!candidates.length) throw new Error(`No rootless voicing for ${symbol} in this register`)
    notes = (previous.length ? VoiceLeading.topNoteDiff(candidates, previous.map(Note.fromMidi)) : candidates[0]).map(pitch)
  } else {
    const root = pitch(`${chord.tonic}${octave}`)
    notes = chordShape(chord.intervals.map(Interval.semitones), mode, inversion).map(interval => root + interval)
  }
  notes.forEach(pitch)
  return notes
}

// Each candidate is a complete close/drop2 inversion or a Tonal rootless
// dictionary voicing in the musician's inclusive register. Dynamic programming
// minimizes total low-to-high voice movement over the entire progression, not
// just the next chord. Equal-cost paths use stable sorted candidate order.
export function voiceLedProgression(symbols, { mode, low, high }) {
  low = pitch(low); high = pitch(high)
  if (low > high) throw new Error('Voicing register low must not exceed high')
  if (!Array.isArray(symbols) || !symbols.length) throw new Error('A voice-led progression needs chords')
  const candidates = symbols.map(symbol => {
    const chord = Chord.get(symbol)
    if (chord.empty || !chord.tonic) throw new Error(`Unknown chord: ${symbol}`)
    let rows = []
    if (mode === 'rootless') {
      if (chord.bass) throw new Error('Rootless voicing does not support an explicit slash-chord bass')
      rows = Voicing.search(symbol, [Note.fromMidi(low), Note.fromMidi(high)], VoicingDictionary.lefthand).map(notes => notes.map(pitch))
    } else {
      const tonic = Note.chroma(chord.tonic)
      // The new range search uses one instance of each chord pitch class in
      // close position, including compound extensions and non-chord slash bass.
      // Existing octave/inversion commands retain their original interval shape.
      const intervals = [...new Set(chord.notes.map(note => (Note.chroma(note) - tonic + 12) % 12))].sort((a, b) => a - b)
      for (let inversion = 0; inversion < intervals.length; inversion++) {
        const shape = chordShape(intervals, mode, inversion)
        const first = Math.ceil((low - tonic - shape[0]) / 12), last = Math.floor((high - tonic - shape.at(-1)) / 12)
        for (let octave = first; octave <= last; octave++) rows.push(shape.map(value => tonic + octave * 12 + value))
      }
    }
    rows = rows.filter(row => row.length && row.every((value, i) => value >= low && value <= high && (!i || value > row[i - 1]))
      && (!chord.bass || row[0] % 12 === Note.chroma(chord.bass)))
    rows = [...new Map(rows.map(row => [row.join(','), row])).values()].sort((a, b) => {
      for (let i = 0; i < Math.min(a.length, b.length); i++) if (a[i] !== b[i]) return a[i] - b[i]
      return a.length - b.length
    })
    if (!rows.length) throw new Error(`No ${mode} voicing for ${symbol} inside the selected register`)
    return rows
  })
  let costs = candidates[0].map(() => 0)
  const predecessors = []
  for (let step = 1; step < candidates.length; step++) {
    const previous = candidates[step - 1], links = []
    const next = candidates[step].map(notes => {
      let best = Infinity, link = -1
      for (const [index, before] of previous.entries()) {
        if (before.length !== notes.length) continue
        const cost = costs[index] + notes.reduce((sum, key, voice) => sum + Math.abs(key - before[voice]), 0)
        if (cost < best) { best = cost; link = index }
      }
      links.push(link)
      return best
    })
    predecessors.push(links); costs = next
  }
  let selected = costs.indexOf(Math.min(...costs))
  if (!Number.isFinite(costs[selected])) throw new Error('Voice-led chords need a constant number of voices')
  const path = new Array(candidates.length)
  for (let step = candidates.length - 1; step >= 0; step--) {
    path[step] = candidates[step][selected]
    if (step) selected = predecessors[step - 1][selected]
  }
  return path
}

// Reassign existing voices, low to high, without replacing their identities,
// rhythm or dynamics. A different voice count needs a separate composition edit.
export function revoiceNotes(notes, tick, symbol, options) {
  int(tick, 'voicing cursor')
  const voices = notes.filter(note => note.duration === 0 ? note.start === tick
    : note.start <= tick && tick < note.start + note.duration).sort((a, b) => a.pitch - b.pitch)
  if (!voices.length) throw new Error('No notes sounding at the cursor in the selected track/channel')
  const pitches = chordVoicing(symbol, { ...options, previous: voices.map(note => note.pitch) })
  if (pitches.length !== voices.length) throw new Error(`Voicing has ${pitches.length} voices; the cursor has ${voices.length}. Use :chord to compose a different number of voices`)
  return voices.map((note, index) => ({ id: note.id, pitch: pitches[index] }))
}

// Every edit is transactional: validate a private candidate before returning it.
// Callers may retain immutable before/after documents for undo and redo.
export function editProject(project, trackId, edit) {
  validateProject(project)
  const next = structuredClone(project)
  const track = next.tracks.find(track => track.id === trackId)
  if (!track) throw new Error('Selected track no longer exists')
  if (track.channel === GM_DRUM_CHANNEL && ['chord', 'revoice', 'progression', 'progression-led'].includes(edit.kind)) {
    throw new Error('Chord voicings need a melodic track; drum notes select percussion sounds')
  }
  const add = note => track.notes.push({ id: uniqueId('note', track.notes), ...note })
  const noteEdit = change => {
    switch (change.kind) {
      case 'note': add({ pitch: pitch(change.pitch), start: change.start, duration: change.duration, velocity: change.velocity }); break
      case 'remove': {
        const index = track.notes.findIndex(note => note.id === change.id)
        if (index < 0) throw new Error('No selected note')
        track.notes.splice(index, 1); break
      }
      case 'change-note': {
        const note = track.notes.find(note => note.id === change.id)
        if (!note) throw new Error('No selected note')
        if (change.pitch !== undefined) note.pitch = pitch(change.pitch)
        for (const key of ['start', 'duration', 'velocity']) if (change[key] !== undefined) note[key] = change[key]
        break
      }
      default: throw new Error('Unknown batch note edit')
    }
  }
  switch (edit.kind) {
    case 'note': case 'remove': case 'change-note': noteEdit(edit); break
    case 'batch-notes': for (const change of edit.changes) noteEdit(change); break
    case 'chord': {
      const notes = chordVoicing(edit.symbol, edit)
      for (const value of notes) add({ pitch: value, start: edit.start, duration: edit.duration, velocity: edit.velocity })
      break
    }
    case 'revoice': {
      const changes = new Map(revoiceNotes(track.notes, edit.tick, edit.symbol, edit).map(note => [note.id, note.pitch]))
      for (const note of track.notes) if (changes.has(note.id)) note.pitch = changes.get(note.id)
      break
    }
    case 'progression': {
      let previous = []
      for (const [index, symbol] of edit.symbols.entries()) {
        previous = chordVoicing(symbol, { ...edit, previous })
        for (const value of previous) add({ pitch: value, start: edit.start + index * edit.duration, duration: edit.duration, velocity: edit.velocity })
      }
      break
    }
    case 'progression-led': {
      const voicings = voiceLedProgression(edit.symbols, edit)
      for (const [index, notes] of voicings.entries()) {
        for (const value of notes) add({ pitch: value, start: edit.start + index * edit.duration, duration: edit.duration, velocity: edit.velocity })
      }
      break
    }
    case 'transpose': for (const note of track.notes) note.pitch += int(edit.semitones, 'transpose', -127, 127); break
    case 'quantize': {
      const grid = int(edit.grid, 'quantize grid', 1)
      for (const note of track.notes) note.start = Math.round(note.start / grid) * grid
      break
    }
    case 'duplicate': {
      const offset = int(edit.offset, 'duplicate offset', 1)
      for (const note of [...track.notes]) { const { id, ...data } = note; add({ ...data, start: data.start + offset }) }
      break
    }
    case 'track': case 'drum-track': {
      const channel = edit.kind === 'drum-track' ? GM_DRUM_CHANNEL
        : MELODIC_CHANNELS.find(channel => !next.tracks.some(track => track.channel === channel))
      if (channel === undefined) throw new Error('All 15 melodic MIDI channels are already assigned')
      if (next.tracks.some(track => track.channel === channel)) throw new Error('GM percussion channel 10 already has a track')
      next.tracks.push({ id: uniqueId('track', next.tracks), name: text(edit.name, 'track name'), channel, program: 0, level: 100, pan: 64, muted: false, solo: false, notes: [] })
      break
    }
    case 'track-settings':
      for (const key of ['muted', 'solo', 'program', 'name', 'level', 'pan']) if (edit[key] !== undefined) track[key] = edit[key]
      break
    case 'tempo': next.tempo = edit.value; break
    case 'title': next.title = edit.value; break
    case 'loop': next.loop = { start: edit.start, end: edit.end }; break
    case 'length':
      next.length = edit.value
      if (next.loop.end === project.length) next.loop.end = edit.value
      break
    case 'meter': next.meter = edit.value; break
    default: throw new Error('Unknown sequencer edit')
  }
  return validateProject(next)
}

// Rendering, .mid export and transport share precisely the same note schedule.
// A loop clips sustained notes at both boundaries, including notes already held.
export function sequenceEvents(project, { loop = false } = {}) {
  validateProject(project)
  const start = loop ? project.loop.start : 0, end = loop ? project.loop.end : project.length
  const events = []
  for (const track of activeTracks(project)) {
    events.push({ tick: 0, kind: 'program', track: track.id, channel: track.channel, program: track.program })
    // General MIDI channel volume and pan are shared by WAV synthesis and .mid.
    events.push({ tick: 0, kind: 'control', track: track.id, channel: track.channel, controller: 7, value: track.level })
    events.push({ tick: 0, kind: 'control', track: track.id, channel: track.channel, controller: 10, value: track.pan })
    for (const note of track.notes) {
      const on = Math.max(start, note.start), off = Math.min(end, note.start + note.duration)
      if (off <= on) continue
      events.push({ tick: on - start, kind: 'on', track: track.id, channel: track.channel, pitch: note.pitch, velocity: note.velocity })
      events.push({ tick: off - start, kind: 'off', track: track.id, channel: track.channel, pitch: note.pitch, velocity: 0 })
    }
  }
  const order = { program: 0, control: 1, off: 2, on: 3 }
  events.sort((a, b) => a.tick - b.tick || order[a.kind] - order[b.kind])
  return { events, ticks: end - start, seconds: (end - start) / PPQ * 60 / project.tempo }
}
