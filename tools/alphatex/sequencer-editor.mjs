import { newProject, validateProject, editProject, beats, pitch, PPQ, harmonyAt } from './sequencer-project.mjs'
import { sourceEditor, sourceSelected, sourceAction, sourceCommand, sourceHarmony, sourceMeterAt } from './midi-source-editor.mjs'
import { validateSound } from './project-sound.mjs'
import { noteSelectionCommand, retainNoteSelection, selectedNotes, moveSelectedNotes } from './note-selection.mjs'
export { selectedNotes } from './note-selection.mjs'

export function editorSound(editor, sound) {
  validateSound(sound)
  const project = { ...editor.project, sound: structuredClone(sound) }
  const previous = { ...editor, undo: [...editor.undo, editor.project], redo: [] }
  return project.kind === 'midi-source' ? sourceEditor(project, previous) : { ...previous, project: validateProject(project) }
}

export function newEditor(project = newProject(), { pattern } = {}) {
  if (project?.kind === 'midi-source') return sourceEditor(project, {}, pattern)
  if (project?.kind !== undefined) throw new Error('Unsupported sequencer editor document')
  validateProject(project)
  const track = Math.max(0, project.tracks.findIndex(track => track.notes.length))
  const first = project.tracks[track].notes.reduce((first, note) =>
    first === null || note.start < first.start ? note : first, null)
  return { project, track, tick: first?.start ?? 0, pitch: first?.pitch ?? 60,
    step: PPQ / 4, duration: PPQ, velocity: 96, undo: [], redo: [] }
}
export function selectedNote(editor) {
  if (editor.project.kind === 'midi-source') return sourceSelected(editor)
  return editor.project.tracks[editor.track].notes.find(note => note.pitch === editor.pitch
    && note.start <= editor.tick && editor.tick < note.start + note.duration)
}
function apply(editor, edit) {
  const project = editProject(editor.project, editor.project.tracks[editor.track].id, edit)
  return { ...editor, project, undo: [...editor.undo, editor.project], redo: [] }
}
export function editorAction(editor, action) {
  const selection = selectedNotes(editor)
  let next
  if (selection.length && action.kind === 'remove') next = noteSelectionCommand(editor, 'delete-notes', [])
  else if (selection.length && action.kind === 'move-note') {
    // Typed raw-tick keyboard movement must not round-trip through decimal beats.
    next = moveSelectedNotes(editor, action.ticks ?? 0, action.pitches ?? 0)
  } else if (selection.length && action.kind === 'toggle-note') throw new Error('Clear the note selection before inserting or toggling one note')
  else next = act(editor, action)
  return retainNoteSelection(editor, next, { history: ['undo', 'redo'].includes(action.kind) })
}
function act(editor, action) {
  if (editor.project.kind === 'midi-source') return sourceAction(editor, action)
  const note = selectedNote(editor)
  switch (action.kind) {
    case 'move': return { ...editor, tick: Math.max(0, Math.min(editor.project.length - 1, editor.tick + (action.ticks ?? 0))),
      pitch: Math.max(0, Math.min(127, editor.pitch + (action.pitches ?? 0))) }
    case 'track': return { ...editor, track: (editor.track + 1) % editor.project.tracks.length }
    case 'toggle-note': return apply(editor, note ? { kind: 'remove', id: note.id }
      : { kind: 'note', pitch: editor.pitch, start: editor.tick, duration: editor.duration, velocity: editor.velocity })
    case 'remove': if (!note) throw new Error('No note at cursor'); return apply(editor, { kind: 'remove', id: note.id })
    case 'move-note': {
      if (!note) throw new Error('No note at cursor')
      const changed = apply(editor, { kind: 'change-note', id: note.id,
        start: note.start + (action.ticks ?? 0), pitch: note.pitch + (action.pitches ?? 0) })
      return { ...changed, tick: editor.tick + (action.ticks ?? 0), pitch: editor.pitch + (action.pitches ?? 0) }
    }
    case 'duration': {
      const duration = action.value
      if (!Number.isSafeInteger(duration) || duration <= 0) throw new Error('Invalid duration')
      return { ...(note ? apply(editor, { kind: 'change-note', id: note.id, duration }) : editor), duration }
    }
    case 'velocity': {
      const velocity = Math.max(1, Math.min(127, action.value))
      return { ...(note ? apply(editor, { kind: 'change-note', id: note.id, velocity }) : editor), velocity }
    }
    case 'grid': {
      const steps = [PPQ / 4, PPQ / 2, PPQ, 2 * PPQ, 4 * PPQ]
      return { ...editor, step: steps[(steps.indexOf(editor.step) + 1) % steps.length] }
    }
    case 'undo': case 'redo': {
      const source = editor[action.kind]
      if (!source.length) return editor
      const project = source.at(-1), other = action.kind === 'undo' ? 'redo' : 'undo'
      const track = Math.min(editor.track, project.tracks.length - 1)
      // Note IDs are scoped to a track. Follow the actual selected voice only
      // when that same track survives; a deleted track must not select its peer.
      const restored = project.tracks[track].id === editor.project.tracks[editor.track].id
        ? project.tracks[track].notes.find(value => value.id === note?.id) : undefined
      const inside = restored && restored.start <= editor.tick && editor.tick < restored.start + restored.duration
      return { ...editor, project, [action.kind]: source.slice(0, -1), [other]: [...editor[other], editor.project],
        track, tick: restored && !inside ? restored.start : Math.min(editor.tick, project.length - 1),
        pitch: restored?.pitch ?? editor.pitch }
    }
    case 'mute': case 'solo': {
      const track = editor.project.tracks[editor.track], field = action.kind === 'mute' ? 'muted' : 'solo'
      return apply(editor, { kind: 'track-settings', [field]: !track[field] })
    }
    default: throw new Error('Unknown editor action')
  }
}

// A small exact command grammar. Commands yield typed effects; the terminal owns IO.
export function stepInputEffect(line) {
  const [command, ...args] = line.trim().split(/\s+/)
  if (command === 'practice-record') {
    if (args.length < 1 || args.length > 2) throw new Error('Use :practice-record PATH [SOURCE_UID]')
    return { kind: 'step-input', source: args[1], monitor: true, practice: true, recording: { path: args[0] } }
  }
  if (command === 'practice-input') {
    if (args.length > 1) throw new Error('Use :practice-input [SOURCE_UID]')
    return { kind: 'step-input', source: args[0], monitor: true, practice: true }
  }
  if (command === 'step-input') {
    const sources = args.filter(arg => arg !== '--monitor')
    if (sources.length > 1 || args.length - sources.length > 1) throw new Error('Use :step-input [SOURCE_UID] [--monitor]')
    return { kind: 'step-input', source: sources[0], ...(args.includes('--monitor') ? { monitor: true } : {}) }
  }
  if (command === 'step-stop') {
    if (args.length) throw new Error('Use :step-stop')
    return { kind: 'step-stop' }
  }
  if (command === 'step-diagnostics') {
    if (args.length !== 1) throw new Error('Use :step-diagnostics PATH')
    return { kind: 'step-diagnostics', path: args[0] }
  }
  if (command === 'step-length' || command === 'step-rest') {
    if (args.length > 1 || (command === 'step-length' && args.length !== 1)) throw new Error(`Use :${command} ${command === 'step-rest' ? '[VALUE]' : 'VALUE'}`)
    return { kind: command, value: args[0] }
  }
}
export function editorCommand(editor, line) {
  const effect = stepInputEffect(line)
  if (effect) return { editor, effect }
  const [command, ...args] = line.trim().split(/\s+/)
  if (command === 'soundfont-fluid') return { editor, effect: { kind: 'soundfont-fluid', ...(args.length ? { path: args.join(' ') } : {}) } }
  const selected = noteSelectionCommand(editor, command, args)
  const result = selected === undefined ? runCommand(editor, line) : { editor: selected }
  return { ...result, editor: retainNoteSelection(editor, result.editor, { history: ['undo', 'redo'].includes(command) }) }
}
function runCommand(editor, line) {
  if (editor.project.kind === 'midi-source') return sourceCommand(editor, line)
  const [command, ...args] = line.trim().split(/\s+/)
  const count = (min, max = min) => {
    if (args.length < min || args.length > max) throw new Error(`Wrong arguments for ${command}; use :help`)
  }
  let edit
  switch (command) {
    case 'note': count(3, 4); edit = { kind: 'note', pitch: pitch(args[0]), start: beats(args[1]), duration: beats(args[2]), velocity: args[3] === undefined ? editor.velocity : Number(args[3]) }; break
    case 'chord': count(3, 6); edit = { kind: 'chord', symbol: args[0], start: beats(args[1]), duration: beats(args[2]), mode: args[3] ?? 'close', octave: args[4] === undefined ? 4 : Number(args[4]), inversion: args[5] === undefined ? 0 : Number(args[5]), velocity: editor.velocity }; break
    case 'revoice': count(2, 4); edit = { kind: 'revoice', tick: editor.tick, symbol: args[0], mode: args[1], octave: args[2] === undefined ? 4 : Number(args[2]), inversion: args[3] === undefined ? 0 : Number(args[3]) }; break
    case 'revoice-led': count(6, Number.MAX_SAFE_INTEGER); edit = { kind: 'revoice-led', start: beats(args[0]), end: beats(args[1]), mode: args[2], low: pitch(args[3]), high: pitch(args[4]), symbols: args.slice(5) }; break
    case 'progression': count(4, Number.MAX_SAFE_INTEGER); edit = { kind: 'progression', start: beats(args[0]), duration: beats(args[1]), mode: args[2], octave: 3, symbols: args.slice(3), velocity: editor.velocity }; break
    case 'progression-led': count(6, Number.MAX_SAFE_INTEGER); edit = { kind: 'progression-led', start: beats(args[0]), duration: beats(args[1]), mode: args[2], low: pitch(args[3]), high: pitch(args[4]), symbols: args.slice(5), velocity: editor.velocity }; break
    case 'tempo': count(1); edit = { kind: 'tempo', value: Number(args[0]) }; break
    case 'length': count(1); edit = { kind: 'length', value: beats(args[0]) }; break
    case 'loop': count(2); edit = { kind: 'loop', start: beats(args[0]), end: beats(args[1]) }; break
    case 'transpose': count(1); edit = { kind: 'transpose', semitones: Number(args[0]) }; break
    case 'quantize': count(1); edit = { kind: 'quantize', grid: beats(args[0]) }; break
    case 'duplicate': count(1); edit = { kind: 'duplicate', offset: beats(args[0]) }; break
    case 'track-add': count(1, Number.MAX_SAFE_INTEGER); edit = { kind: 'track', name: args.join(' ') }; break
    case 'drum-track': count(1, Number.MAX_SAFE_INTEGER); edit = { kind: 'drum-track', name: args.join(' ') }; break
    case 'title': count(1, Number.MAX_SAFE_INTEGER); edit = { kind: 'title', value: args.join(' ') }; break
    case 'rename': count(1, Number.MAX_SAFE_INTEGER); edit = { kind: 'track-settings', name: args.join(' ') }; break
    case 'program': count(1); edit = { kind: 'track-settings', program: Number(args[0]) }; break
    case 'level': case 'pan': count(1); edit = { kind: 'track-settings', [command]: Number(args[0]) }; break
    case 'meter': count(2); edit = { kind: 'meter', value: args.map(Number) }; break
    case 'track': {
      count(1); const index = Number(args[0]) - 1
      if (!Number.isInteger(index) || index < 0 || index >= editor.project.tracks.length) throw new Error('Unknown track')
      return { editor: { ...editor, track: index } }
    }
    case 'cursor': count(2); {
      const tick = beats(args[0])
      if (tick >= editor.project.length) throw new Error('Cursor outside project')
      return { editor: { ...editor, tick, pitch: pitch(args[1]) } }
    }
    case 'harmony':
      count(0, 1)
      if (args[0] !== undefined && !['mix', 'track'].includes(args[0])) throw new Error('Use :harmony mix or :harmony track')
      return { editor, effect: { kind: 'harmony', scope: args[0] ?? 'mix' } }
    case 'harmony-export': count(1, Number.MAX_SAFE_INTEGER); return { editor, effect: { kind: 'harmony-export', path: args.join(' ') } }
    case 'save': case 'play': case 'stop': case 'record': case 'help': case 'arrange':
      count(0); return { editor, effect: { kind: command } }
    case 'save-as': case 'export': case 'wave': case 'output': case 'midi-output':
      count(1, Number.MAX_SAFE_INTEGER); return { editor, effect: { kind: command, path: args.join(' ') } }
    case 'seek': count(1); return { editor, effect: { kind: 'seek', tick: beats(args[0]) } }
    case 'audio': count(0); return { editor, effect: { kind: 'audio' } }
    case 'undo': case 'redo': case 'mute': case 'solo':
      count(0); return { editor: editorAction(editor, { kind: command }) }
    default: throw new Error(`Unknown command: ${command}; use :help`)
  }
  const next = apply(editor, edit)
  if (command === 'revoice' || command === 'revoice-led') {
    const selected = selectedNote(editor)
    const voice = next.project.tracks[next.track].notes.find(note => note.id === selected?.id)
    return { editor: voice ? { ...next, pitch: voice.pitch } : next }
  }
  return { editor: ['track-add', 'drum-track'].includes(command) ? { ...next, track: next.project.tracks.length - 1,
    ...(command === 'drum-track' ? { pitch: 36 } : {}) } : next,
    ...(command === 'loop' ? { effect: { kind: 'loop' } } : {}) }
}

export const editorView = editor => editor.project.kind === 'midi-source' ? { ...editor.view, meter: sourceMeterAt(editor) } : editor.view ?? editor.project
export const editorAxis = editor => editor.axis ?? { per: PPQ, label: 'beats' }
export const editorHarmony = editor => editor.project.kind === 'midi-source' ? sourceHarmony(editor) : harmonyAt(editor.project, editor.tick)
