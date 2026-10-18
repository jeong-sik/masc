import { newProject, editProject, beats, pitch, PPQ } from './sequencer-project.mjs'

export function newEditor(project = newProject()) {
  return { project, track: 0, tick: 0, pitch: 60, step: PPQ / 4, duration: PPQ, velocity: 96, undo: [], redo: [] }
}
export function selectedNote(editor) {
  return editor.project.tracks[editor.track].notes.find(note => note.pitch === editor.pitch
    && note.start <= editor.tick && editor.tick < note.start + note.duration)
}
function apply(editor, edit) {
  const project = editProject(editor.project, editor.project.tracks[editor.track].id, edit)
  return { ...editor, project, undo: [...editor.undo, editor.project], redo: [] }
}
export function editorAction(editor, action) {
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
      return { ...editor, project, [action.kind]: source.slice(0, -1), [other]: [...editor[other], editor.project],
        track: Math.min(editor.track, project.tracks.length - 1), tick: Math.min(editor.tick, project.length - 1) }
    }
    case 'mute': case 'solo': {
      const track = editor.project.tracks[editor.track], field = action.kind === 'mute' ? 'muted' : 'solo'
      return apply(editor, { kind: 'track-settings', [field]: !track[field] })
    }
    default: throw new Error('Unknown editor action')
  }
}

// A small exact command grammar. Commands yield typed effects; the terminal owns IO.
export function editorCommand(editor, line) {
  const [command, ...args] = line.trim().split(/\s+/)
  const count = (min, max = min) => {
    if (args.length < min || args.length > max) throw new Error(`Wrong arguments for ${command}; use :help`)
  }
  let edit
  switch (command) {
    case 'note': count(3, 4); edit = { kind: 'note', pitch: pitch(args[0]), start: beats(args[1]), duration: beats(args[2]), velocity: args[3] === undefined ? editor.velocity : Number(args[3]) }; break
    case 'chord': count(3, 6); edit = { kind: 'chord', symbol: args[0], start: beats(args[1]), duration: beats(args[2]), mode: args[3] ?? 'close', octave: args[4] === undefined ? 4 : Number(args[4]), inversion: args[5] === undefined ? 0 : Number(args[5]), velocity: editor.velocity }; break
    case 'progression': count(4, Number.MAX_SAFE_INTEGER); edit = { kind: 'progression', start: beats(args[0]), duration: beats(args[1]), mode: args[2], octave: 3, symbols: args.slice(3), velocity: editor.velocity }; break
    case 'tempo': count(1); edit = { kind: 'tempo', value: Number(args[0]) }; break
    case 'length': count(1); edit = { kind: 'length', value: beats(args[0]) }; break
    case 'loop': count(2); edit = { kind: 'loop', start: beats(args[0]), end: beats(args[1]) }; break
    case 'transpose': count(1); edit = { kind: 'transpose', semitones: Number(args[0]) }; break
    case 'quantize': count(1); edit = { kind: 'quantize', grid: beats(args[0]) }; break
    case 'duplicate': count(1); edit = { kind: 'duplicate', offset: beats(args[0]) }; break
    case 'track-add': count(1, Number.MAX_SAFE_INTEGER); edit = { kind: 'track', name: args.join(' ') }; break
    case 'title': count(1, Number.MAX_SAFE_INTEGER); edit = { kind: 'title', value: args.join(' ') }; break
    case 'rename': count(1, Number.MAX_SAFE_INTEGER); edit = { kind: 'track-settings', name: args.join(' ') }; break
    case 'program': count(1); edit = { kind: 'track-settings', program: Number(args[0]) }; break
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
    case 'save': case 'play': case 'stop': case 'record': case 'help':
      count(0); return { editor, effect: { kind: command } }
    case 'save-as': case 'export': case 'wave':
      count(1, Number.MAX_SAFE_INTEGER); return { editor, effect: { kind: command, path: args.join(' ') } }
    case 'undo': case 'redo': case 'mute': case 'solo':
      count(0); return { editor: editorAction(editor, { kind: command }) }
    default: throw new Error(`Unknown command: ${command}; use :help`)
  }
  const next = apply(editor, edit)
  return { editor: command === 'track-add' ? { ...next, track: next.project.tracks.length - 1 } : next }
}
