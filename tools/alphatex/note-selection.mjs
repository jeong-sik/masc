import { quantizeTick, quantizedStarts } from './note-quantize.mjs'
import { assertMidiTimingOrder, assertNoNewNoteOverlaps } from './note-overlap.mjs'
import { pitch, editProject } from './sequencer-project.mjs'
import { editMidiSourceNotes } from './midi-source.mjs'
import { sourceEditor } from './midi-source-editor.mjs'
import { tickUnits } from './tick-units.mjs'

const source = editor => editor.project.kind === 'midi-source'
const view = editor => editor.view ?? editor.project
const track = editor => view(editor).tracks[editor.track]
const scope = editor => ({ track: track(editor).id, pattern: editor.pattern, channel: editor.channel })
const sameScope = (a, b) => a.track === b.track && a.pattern === b.pattern && a.channel === b.channel
const integer = (value, label) => {
  if (!Number.isSafeInteger(value)) throw new Error(`Invalid ${label}`)
  return value
}
function units(editor, value, signed = false) {
  return tickUnits(value, source(editor) ? editor.axis.per : editor.project.ppq,
    { signed, label: 'Selection time' })
}
export function selectedNotes(editor) {
  const selection = editor.noteSelection
  if (!selection || editor.eventView || !sameScope(selection.scope, scope(editor))) return []
  const ids = new Set(selection.ids)
  return track(editor).notes.filter(note => ids.has(note.id))
}
// A selection belongs to one track/pattern/channel. It never springs back when
// returning to an old context, or retargets IDs restored by undo/redo.
export function retainNoteSelection(previous, next, { history = false } = {}) {
  if (!next.noteSelection) return next
  if (history || next.eventView || !sameScope(scope(previous), scope(next))) return { ...next, noteSelection: undefined }
  const ids = selectedNotes(next).map(note => note.id)
  return { ...next, noteSelection: ids.length ? { ...next.noteSelection, ids } : undefined }
}
function chosen(editor) {
  const notes = selectedNotes(editor)
  if (!notes.length) throw new Error('Select notes with :select-notes or :select-all first')
  return notes
}
function select(editor, notes, origin) {
  if (!notes.length) throw new Error('No note onsets in the selected time and pitch range')
  return { ...editor, eventView: undefined, noteSelection: { scope: scope(editor), ids: notes.map(note => note.id), origin } }
}
function apply(editor, changes) {
  const project = source(editor)
    ? editMidiSourceNotes(editor.project, changes, { pattern: editor.pattern })
    : editProject(editor.project, track(editor).id, { kind: 'batch-notes', changes })
  const previous = { ...editor, undo: [...editor.undo, editor.project], redo: [] }
  return source(editor) ? sourceEditor(project, previous) : { ...previous, project }
}
function clipboard(editor) {
  const notes = chosen(editor), origin = editor.noteSelection.origin
  const events = new Map((editor.performance?.events ?? []).map(event => [event.id, event]))
  return { clock: source(editor) ? editor.info.timing : { kind: 'ppq', ppq: editor.project.ppq },
    notes: notes.map(note => {
      const off = events.get(note.off)
      return { pitch: note.pitch, start: note.start - origin, duration: note.duration, velocity: note.velocity,
        ...(source(editor) ? { channel: note.channel, port: note.port,
          release: off.bytes[0] >> 4 === 8 ? { kind: 'note-off', velocity: off.bytes[2] } : { kind: 'note-on-zero' } } : {}) }
    }) }
}
function transpose(value) { return integer(Number(value), 'transposition') }
export function moveSelectedNotes(editor, offset, semitones) {
  integer(offset, 'selection offset'); integer(semitones, 'transposition')
  const notes = chosen(editor), origin = integer(editor.noteSelection.origin + offset, 'selection anchor')
  if (origin < 0) throw new Error('Move places the selection anchor before zero')
  const next = apply(editor, notes.map(note => ({ kind: source(editor) ? 'change' : 'change-note', id: note.id,
    start: note.start + offset, pitch: note.pitch + semitones })))
  return { ...next, tick: Math.max(0, Math.min(view(next).length - 1, editor.tick + offset)),
    pitch: Math.max(0, Math.min(127, editor.pitch + semitones)), noteSelection: { ...next.noteSelection, origin } }
}
export function noteSelectionCommand(editor, command, args) {
  const count = (low, high = low) => {
    if (args.length < low || args.length > high) throw new Error(`Wrong arguments for ${command}; use :help`)
  }
  switch (command) {
    case 'select-notes': {
      count(2, 4)
      if (args.length === 3) throw new Error('Supply both low and high pitches')
      const start = units(editor, args[0]), end = units(editor, args[1])
      const low = args.length === 4 ? pitch(args[2]) : 0, high = args.length === 4 ? pitch(args[3]) : 127
      if (start >= end || end > (view(editor).displayLength ?? view(editor).length) || low > high) throw new Error('Invalid selection range')
      const notes = track(editor).notes.filter(note => note.start >= start && note.start < end && note.pitch >= low && note.pitch <= high
        && (editor.channel === undefined || note.channel === editor.channel))
      return select(editor, notes, start)
    }
    case 'select-all': {
      count(0)
      const notes = track(editor).notes.filter(note => editor.channel === undefined || note.channel === editor.channel)
      return select(editor, notes, notes.reduce((first, note) => Math.min(first, note.start), Infinity))
    }
    case 'clear-selection': count(0); return { ...editor, noteSelection: undefined }
    case 'copy-notes': count(0); return { ...editor, noteClipboard: clipboard(editor) }
    case 'cut-notes': {
      count(0); const copied = clipboard(editor)
      return { ...apply(editor, chosen(editor).map(note => ({ kind: 'remove', id: note.id }))), noteClipboard: copied, noteSelection: undefined }
    }
    case 'delete-notes': count(0); return { ...apply(editor, chosen(editor).map(note => ({ kind: 'remove', id: note.id }))), noteSelection: undefined }
    case 'move-notes': {
      count(2); const offset = units(editor, args[0], true), semitones = transpose(args[1])
      return moveSelectedNotes(editor, offset, semitones)
    }
    case 'quantize-notes': {
      count(1)
      const grid = units(editor, args[0])
      if (!grid) throw new Error('Quantize grid must be positive')
      const notes = chosen(editor)
      const starts = source(editor) ? new Map(notes.map(note => [note.id,quantizeTick(note.start,grid)]))
        : quantizedStarts(track(editor).notes, notes, grid)
      const next = apply(editor, notes.map(note => ({ kind: source(editor) ? 'change' : 'change-note',
        id: note.id, start: starts.get(note.id) })))
      if (source(editor)) assertMidiTimingOrder(editor.performance,next.performance)
      return { ...next, noteSelection: { ...next.noteSelection, origin: quantizeTick(editor.noteSelection.origin, grid) } }
    }
    case 'duration-notes': case 'duration-add-notes': {
      count(1)
      const relative = command === 'duration-add-notes', value = units(editor, args[0], relative)
      const notes = chosen(editor), changes = notes.map(note => {
        const duration = integer(relative ? note.duration + value : value, 'note duration')
        if (duration < (source(editor) ? 0 : 1)) throw new Error('Note duration is outside the document range')
        integer(note.start + duration, 'note release position')
        return {kind:source(editor)?'change':'change-note',id:note.id,duration}
      })
      if (!source(editor)) assertNoNewNoteOverlaps(track(editor).notes, changes)
      const next = apply(editor, changes)
      if (source(editor)) assertMidiTimingOrder(editor.performance,next.performance)
      return next
    }
    case 'velocity-notes': case 'velocity-add-notes': {
      count(1)
      const value = integer(Number(args[0]), 'note velocity')
      return apply(editor, chosen(editor).map(note => ({
        kind: source(editor) ? 'change' : 'change-note', id: note.id,
        velocity: command === 'velocity-notes' ? value : note.velocity + value,
      })))
    }
    case 'paste-notes': {
      count(0, 2)
      const copied = editor.noteClipboard
      if (!copied?.notes.length) throw new Error('Copy or cut notes before pasting')
      const clock = source(editor) ? editor.info.timing : { kind: 'ppq', ppq: editor.project.ppq }
      if (copied.clock.kind !== clock.kind || (clock.kind === 'ppq' ? copied.clock.ppq !== clock.ppq
        : copied.clock.frameCode !== clock.frameCode || copied.clock.ticksPerFrame !== clock.ticksPerFrame)) throw new Error('Clipboard uses a different original MIDI clock')
      const at = args.length ? units(editor, args[0]) : editor.tick, semitones = args.length === 2 ? transpose(args[1]) : 0
      const before = new Set(track(editor).notes.map(note => note.id))
      const portAt = tick => editor.performance.events.filter(event => event.track === track(editor).sourceTrack
        && event.tick <= tick && event.kind === 'meta' && event.type === 0x21).at(-1)?.data[0] ?? 0
      const changes = copied.notes.map(note => {
        const start = at + note.start
        if (source(editor) && (portAt(start) !== note.port || portAt(start + note.duration) !== note.port)) throw new Error('Paste changes the source port; choose a matching target track/position')
        return { kind: source(editor) ? 'insert' : 'note', pitch: note.pitch + semitones, start, duration: note.duration, velocity: note.velocity,
          ...(source(editor) ? { track: track(editor).sourceTrack, channel: editor.channel ?? note.channel, release: note.release } : {}) }
      })
      const next = apply(editor, changes)
      return select(next, track(next).notes.filter(note => !before.has(note.id)), at)
    }
    default: return undefined
  }
}
