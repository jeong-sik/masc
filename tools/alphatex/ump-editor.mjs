import { isDeepStrictEqual } from 'node:util'
import { absoluteUmpPitch, umpSourceNotes, editUmpNotes, revoiceUmpNotes, umpOnsetHarmony } from './ump-source.mjs'

export function newUmpEditor(asset, packets) {
  const notes = umpSourceNotes(packets, asset.ump, asset.parts.midi.sha256)
  if (!notes.length) throw new Error('Captured source has no native MIDI2 NoteOn events to edit')
  return { asset, packets, notes, selected: notes[0].id, undo: [], redo: [] }
}
function adopt(editor, asset, history = {}) {
  return { ...editor, ...history, asset, notes: umpSourceNotes(editor.packets, asset.ump, asset.parts.midi.sha256) }
}
function change(editor, ump) {
  const asset = { ...editor.asset, ump }
  if (!ump.notes.length) delete asset.ump
  if (isDeepStrictEqual(asset, editor.asset)) return editor
  return adopt(editor, asset, { undo: [...editor.undo, editor.asset], redo: [] })
}
export function umpEditorAction(editor, action) {
  if (action.kind === 'select') {
    if (!editor.notes.some(note => note.id === action.id)) throw new Error('Unknown native MIDI2 note identity')
    return { ...editor, selected: action.id }
  }
  if (action.kind === 'move') {
    const index = editor.notes.findIndex(note => note.id === editor.selected)
    return { ...editor, selected: editor.notes[Math.max(0, Math.min(editor.notes.length - 1, index + action.direction))].id }
  }
  if (['undo', 'redo'].includes(action.kind)) {
    const from = editor[action.kind], other = action.kind === 'undo' ? 'redo' : 'undo'
    return from.length ? adopt(editor, from.at(-1), { [action.kind]: from.slice(0, -1), [other]: [...editor[other], editor.asset] }) : editor
  }
  throw new Error('Unknown UMP editor action')
}
export function umpEditorCommand(editor, line) {
  const [command, ...args] = line.trim().split(/\s+/)
  const count = (min, max = min) => { if (args.length < min || args.length > max) throw new Error(`Wrong arguments for ${command}; use :help`) }
  const hash = editor.asset.parts.midi.sha256, current = editor.asset.ump
  switch (command) {
    case 'select': count(1); return { editor: umpEditorAction(editor, { kind: 'select', id: args[0] }) }
    case 'scope': {
      count(3)
      const group = Number(args[1]), channel = Number(args[2])
      if (![group, channel].every(value => Number.isSafeInteger(value) && value >= 1 && value <= 16)) throw new Error('Groups and channels use 1–16')
      const note = editor.notes.find(note => note.source === args[0] && note.group === group - 1 && note.channel === channel - 1)
      if (!note) throw new Error('Scope has no native MIDI2 notes')
      return { editor: { ...editor, selected: note.id } }
    }
    case 'pitch-absolute': case 'velocity': {
      count(1)
      const field = command === 'pitch-absolute' ? 'pitch' : 'velocity'
      const value = field === 'pitch' ? absoluteUmpPitch(args[0]) : Number(args[0])
      return { editor: change(editor, editUmpNotes(editor.packets, current, hash, [{ kind: 'note', id: editor.selected, [field]: value }])) }
    }
    case 'reset-note': count(0); return { editor: change(editor, editUmpNotes(editor.packets, current, hash, [{ kind: 'reset', id: editor.selected }])) }
    case 'revoice': {
      count(2, 4)
      return { editor: change(editor, revoiceUmpNotes(editor.packets, current, hash, editor.selected, args[0], {
        mode: args[1], octave: args[2] === undefined ? 4 : Number(args[2]), inversion: args[3] === undefined ? 0 : Number(args[3]) })) }
    }
    case 'harmony': count(0); return { editor, harmony: umpOnsetHarmony(editor.notes, editor.selected) }
    case 'undo': case 'redo': count(0); return { editor: umpEditorAction(editor, { kind: command }) }
    case 'play': case 'help': count(0); return { editor, effect: { kind: command } }
    case 'export': count(1, Number.MAX_SAFE_INTEGER); return { editor, effect: { kind: command, path: line.trim().slice(command.length).trimStart() } }
    default: throw new Error(`Unknown UMP command: ${command}; use :help`)
  }
}
