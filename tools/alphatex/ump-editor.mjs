import { isDeepStrictEqual } from 'node:util'
import { absoluteUmpPitch, umpSourceView, editUmpNotes, editUmpExpressions, revoiceUmpNotes, umpOnsetHarmony } from './ump-source.mjs'

export function newUmpEditor(asset, packets) {
  const { notes, expressions } = umpSourceView(packets, asset.ump, asset.parts.midi.sha256)
  if (!notes.length && !expressions.length) throw new Error('Captured source has no native MIDI2 notes or per-note expression events to edit')
  return { asset, packets, notes, expressions, selection: notes.length ? { kind: 'note', id: notes[0].id } : { kind: 'expression', id: expressions[0].id }, undo: [], redo: [] }
}
function adopt(editor, asset, history = {}) {
  return { ...editor, ...history, asset, ...umpSourceView(editor.packets, asset.ump, asset.parts.midi.sha256) }
}
function change(editor, ump) {
  const asset = { ...editor.asset, ump }
  if (!ump.notes.length && !ump.expressions?.length) delete asset.ump
  if (isDeepStrictEqual(asset, editor.asset)) return editor
  return adopt(editor, asset, { undo: [...editor.undo, editor.asset], redo: [] })
}
export function umpEditorAction(editor, action) {
  if (action.kind === 'select' || action.kind === 'select-expression') {
    const kind = action.kind === 'select' ? 'note' : 'expression', rows = kind === 'note' ? editor.notes : editor.expressions
    if (!rows.some(row => row.id === action.id)) throw new Error(`Unknown native MIDI2 ${kind} identity`)
    return { ...editor, selection: { kind, id: action.id } }
  }
  if (action.kind === 'view') {
    if (!['note', 'expression'].includes(action.view)) throw new Error('Unknown native MIDI2 view')
    const rows = action.view === 'note' ? editor.notes : editor.expressions
    if (!rows.length) throw new Error(`Captured source has no native MIDI2 ${action.view} events`)
    return { ...editor, selection: editor.selection.kind === action.view ? editor.selection : { kind: action.view, id: rows[0].id } }
  }
  if (action.kind === 'move') {
    const rows = editor.selection.kind === 'note' ? editor.notes : editor.expressions
    const index = rows.findIndex(row => row.id === editor.selection.id)
    return { ...editor, selection: { ...editor.selection, id: rows[Math.max(0, Math.min(rows.length - 1, index + action.direction))].id } }
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
  const selected = kind => {
    if (editor.selection.kind !== kind) throw new Error(`Select the native MIDI2 ${kind} view first`)
    return editor.selection.id
  }
  switch (command) {
    case 'select': count(1); return { editor: umpEditorAction(editor, { kind: 'select', id: args[0] }) }
    case 'select-expression': count(1); return { editor: umpEditorAction(editor, { kind: 'select-expression', id: args[0] }) }
    case 'notes': case 'expressions': count(0); return { editor: umpEditorAction(editor, { kind: 'view', view: command === 'notes' ? 'note' : 'expression' }) }
    case 'scope': {
      count(3)
      const group = Number(args[1]), channel = Number(args[2])
      if (![group, channel].every(value => Number.isSafeInteger(value) && value >= 1 && value <= 16)) throw new Error('Groups and channels use 1–16')
      const rows = editor.selection.kind === 'note' ? editor.notes : editor.expressions
      const row = rows.find(row => row.source === args[0] && row.group === group - 1 && row.channel === channel - 1)
      if (!row) throw new Error(`Scope has no native MIDI2 ${editor.selection.kind} events`)
      return { editor: { ...editor, selection: { ...editor.selection, id: row.id } } }
    }
    case 'pitch-absolute': case 'velocity': {
      count(1)
      const field = command === 'pitch-absolute' ? 'pitch' : 'velocity'
      const value = field === 'pitch' ? absoluteUmpPitch(args[0]) : Number(args[0])
      return { editor: change(editor, editUmpNotes(editor.packets, current, hash, [{ kind: 'note', id: selected('note'), [field]: value }])) }
    }
    case 'value32': {
      count(1)
      if (!/^(0|[1-9][0-9]*)$/.test(args[0])) throw new Error('Use an unsigned decimal MIDI2 data word from 0 through 4294967295')
      return { editor: change(editor, editUmpExpressions(editor.packets, current, hash, [{ kind: 'expression', id: selected('expression'), value: Number(args[0]) }])) }
    }
    case 'reset-expression': count(0); return { editor: change(editor, editUmpExpressions(editor.packets, current, hash, [{ kind: 'reset', id: selected('expression') }])) }
    case 'reset-note': count(0); return { editor: change(editor, editUmpNotes(editor.packets, current, hash, [{ kind: 'reset', id: selected('note') }])) }
    case 'revoice': {
      count(2, 4)
      return { editor: change(editor, revoiceUmpNotes(editor.packets, current, hash, selected('note'), args[0], {
        mode: args[1], octave: args[2] === undefined ? 4 : Number(args[2]), inversion: args[3] === undefined ? 0 : Number(args[3]) })) }
    }
    case 'harmony': count(0); return { editor, harmony: umpOnsetHarmony(editor.notes, selected('note')) }
    case 'undo': case 'redo': count(0); return { editor: umpEditorAction(editor, { kind: command }) }
    case 'play': case 'help': count(0); return { editor, effect: { kind: command } }
    case 'export': count(1, Number.MAX_SAFE_INTEGER); return { editor, effect: { kind: command, path: line.trim().slice(command.length).trimStart() } }
    default: throw new Error(`Unknown UMP command: ${command}; use :help`)
  }
}
