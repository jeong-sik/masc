import { isDeepStrictEqual } from 'node:util'
import { captureRange, captureHostAtSeconds, captureSecondsAtHost, captureSecondsToTicks, captureBeatsToTicks, captureHostAtBeats } from './capture-time.mjs'
import { binary } from './exact-time.mjs'
import { scaleTicks } from './tick-units.mjs'
import { absoluteUmpPitch, umpSourceView, editUmpNotes, editUmpExpressions, editUmpTimes, editUmpNoteTime, revoiceUmpNotes, umpOnsetHarmony } from './ump-source.mjs'

export function newUmpEditor(asset, packets, { tempo } = {}) {
  if (tempo !== undefined) binary(tempo)
  const { notes, expressions, events } = umpSourceView(packets, asset.ump, asset.parts.midi.sha256)
  if (!events.length) throw new Error('Captured source has no UMP events to edit')
  return { asset, packets, tempo, notes, expressions, events, selection: notes.length ? { kind: 'note', id: notes[0].id }
    : expressions.length ? { kind: 'expression', id: expressions[0].id } : { kind: 'event', id: events[0].id }, eventSelection: [], undo: [], redo: [] }
}
export const umpEditorRows = editor => editor.selection.kind === 'note' ? editor.notes : editor.selection.kind === 'expression' ? editor.expressions : editor.events
function adopt(editor, asset, history = {}) {
  return { ...editor, ...history, asset, ...umpSourceView(editor.packets, asset.ump, asset.parts.midi.sha256) }
}
function change(editor, ump) {
  const asset = { ...editor.asset, ump }
  if (!ump.notes.length && !ump.expressions?.length && !ump.timing?.length) delete asset.ump
  if (isDeepStrictEqual(asset, editor.asset)) return editor
  return adopt(editor, asset, { undo: [...editor.undo, editor.asset], redo: [] })
}
export function umpEditorAction(editor, action) {
  if (['select', 'select-expression', 'select-event'].includes(action.kind)) {
    const kind = action.kind === 'select' ? 'note' : action.kind === 'select-expression' ? 'expression' : 'event', rows = umpEditorRows({ ...editor, selection: { kind } })
    if (!rows.some(row => row.id === action.id)) throw new Error(`Unknown native MIDI2 ${kind} identity`)
    return { ...editor, selection: { kind, id: action.id } }
  }
  if (action.kind === 'view') {
    if (!['note', 'expression', 'event'].includes(action.view)) throw new Error('Unknown UMP view')
    const rows = umpEditorRows({ ...editor, selection: { kind: action.view } })
    if (!rows.length) throw new Error(`Captured source has no native MIDI2 ${action.view} events`)
    return { ...editor, selection: editor.selection.kind === action.view ? editor.selection : { kind: action.view, id: rows[0].id } }
  }
  if (action.kind === 'move') {
    const rows = umpEditorRows(editor)
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
  const group = () => {
    if (!editor.eventSelection.length) throw new Error('Select original events with :select-events PACKET:WORD... first')
    const ids = new Set(editor.eventSelection), events = editor.events.filter(event => ids.has(event.id))
    if (events.length !== ids.size) throw new Error('The native event selection is stale')
    return events
  }
  const timeGroup = transform => change(editor, editUmpTimes(editor.packets, current, hash,
    group().map(event => ({ kind: 'time', id: event.id, hostTime: String(transform(BigInt(event.hostTime))) }))))
  switch (command) {
    case 'select-events': {
      count(1, Number.MAX_SAFE_INTEGER)
      const ids = new Set(args), available = new Set(editor.events.map(event => event.id))
      if (ids.size !== args.length || args.some(id => !available.has(id))) throw new Error('Select distinct original UMP packet:word identities')
      return { editor: { ...editor, eventSelection: [...args] } }
    }
    case 'deselect-events': count(0); return { editor: { ...editor, eventSelection: [] } }
    case 'reset-event-times': count(0); return { editor: change(editor, editUmpTimes(editor.packets, current, hash,
      group().map(event => ({ kind: 'reset', id: event.id })))) }
    case 'shift-events-ticks': case 'shift-events-seconds': case 'shift-events-beats': {
      count(1)
      let offset
      if (command === 'shift-events-ticks') {
        if (!/^(0|-?[1-9][0-9]*)$/.test(args[0])) throw new Error('Use an exact signed host-tick offset')
        offset = BigInt(args[0])
      } else offset = command === 'shift-events-seconds' ? captureSecondsToTicks(editor.asset, args[0])
        : captureBeatsToTicks(editor.asset, args[0], editor.tempo)
      return { editor: timeGroup(tick => tick + offset) }
    }
    case 'stretch-events': {
      count(1, 2)
      const anchor = args[1] === undefined ? group().reduce((min, event) => BigInt(event.hostTime) < min ? BigInt(event.hostTime) : min,
        BigInt(group()[0].hostTime)) : BigInt(captureHostAtBeats(editor.asset, args[1], editor.tempo))
      return { editor: timeGroup(tick => anchor + scaleTicks(tick - anchor, args[0])) }
    }
    case 'select': count(1); return { editor: umpEditorAction(editor, { kind: 'select', id: args[0] }) }
    case 'select-expression': count(1); return { editor: umpEditorAction(editor, { kind: 'select-expression', id: args[0] }) }
    case 'select-event': count(1); return { editor: umpEditorAction(editor, { kind: 'select-event', id: args[0] }) }
    case 'notes': case 'expressions': case 'events': count(0); return { editor: umpEditorAction(editor, { kind: 'view', view: command === 'notes' ? 'note' : command === 'expressions' ? 'expression' : 'event' }) }
    case 'scope': {
      count(3)
      const group = Number(args[1]), channel = Number(args[2])
      if (![group, channel].every(value => Number.isSafeInteger(value) && value >= 1 && value <= 16)) throw new Error('Groups and channels use 1–16')
      const rows = umpEditorRows(editor)
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
    case 'time': count(1); return { editor: change(editor, editUmpTimes(editor.packets, current, hash, [{ kind: 'time', id: editor.selection.id, hostTime: args[0] }])) }
    case 'at-seconds': count(1); return { editor: change(editor, editUmpTimes(editor.packets, current, hash, [{ kind: 'time', id: editor.selection.id, hostTime: captureHostAtSeconds(editor.asset, args[0]) }])) }
    case 'at-beats': count(1); return { editor: change(editor, editUmpTimes(editor.packets, current, hash, [{ kind: 'time', id: editor.selection.id, hostTime: captureHostAtBeats(editor.asset, args[0], editor.tempo) }])) }
    case 'shift-beats': {
      count(1)
      const event = editor.events.find(event => event.id === editor.selection.id)
      return { editor: change(editor, editUmpTimes(editor.packets, current, hash, [{ kind: 'time', id: event.id,
        hostTime: String(BigInt(event.hostTime) + captureBeatsToTicks(editor.asset, args[0], editor.tempo)) }])) }
    }
    case 'shift-seconds': {
      count(1)
      const event = editor.events.find(event => event.id === editor.selection.id)
      return { editor: change(editor, editUmpTimes(editor.packets, current, hash, [{ kind: 'time', id: event.id,
        hostTime: String(BigInt(event.hostTime) + captureSecondsToTicks(editor.asset, args[0])) }])) }
    }
    case 'shift-time': {
      count(1)
      if (!/^(0|-?[1-9][0-9]*)$/.test(args[0])) throw new Error('Use an exact signed host-tick offset')
      const event = editor.events.find(event => event.id === editor.selection.id)
      return { editor: change(editor, editUmpTimes(editor.packets, current, hash, [{ kind: 'time', id: event.id, hostTime: String(BigInt(event.hostTime) + BigInt(args[0])) }])) }
    }
    case 'reset-time': count(0); return { editor: change(editor, editUmpTimes(editor.packets, current, hash, [{ kind: 'reset', id: editor.selection.id }])) }
    case 'note-time': count(3); return { editor: change(editor, editUmpNoteTime(editor.packets, current, hash, selected('note'), args[0], args[1], args[2])) }
    case 'note-seconds': count(3); return { editor: change(editor, editUmpNoteTime(editor.packets, current, hash, selected('note'), args[0],
      captureHostAtSeconds(editor.asset, args[1]), captureHostAtSeconds(editor.asset, args[2]))) }
    case 'note-beats': count(3); return { editor: change(editor, editUmpNoteTime(editor.packets, current, hash, selected('note'), args[0],
      captureHostAtBeats(editor.asset, args[1], editor.tempo), captureHostAtBeats(editor.asset, args[2], editor.tempo))) }
    case 'duration-beats': {
      count(2)
      const ticks = captureBeatsToTicks(editor.asset, args[1], editor.tempo), on = editor.notes.find(note => note.id === selected('note'))
      if (ticks <= 0n) throw new Error('Duration must round to at least one positive host tick')
      return { editor: change(editor, editUmpNoteTime(editor.packets, current, hash, on.id, args[0], on.hostTime, String(BigInt(on.hostTime) + ticks))) }
    }
    case 'duration-seconds': {
      count(2)
      const ticks = captureSecondsToTicks(editor.asset, args[1]), on = editor.notes.find(note => note.id === selected('note'))
      if (ticks <= 0n) throw new Error('Duration must round to at least one positive host tick')
      return { editor: change(editor, editUmpNoteTime(editor.packets, current, hash, on.id, args[0], on.hostTime, String(BigInt(on.hostTime) + ticks))) }
    }
    case 'clock': {
      count(0)
      const event = editor.events.find(event => event.id === editor.selection.id)
      return { editor, clock: { sourceOrigin: captureRange({ ...editor.asset, ump: undefined }).origin,
        hostTime: event.hostTime, originalHostTime: event.originalHostTime, seconds: captureSecondsAtHost(editor.asset, event.hostTime) } }
    }
    case 'duration-ticks': {
      count(2)
      if (!/^[1-9][0-9]*$/.test(args[1])) throw new Error('Use a positive exact host-tick duration')
      const on = editor.notes.find(note => note.id === selected('note'))
      return { editor: change(editor, editUmpNoteTime(editor.packets, current, hash, on.id, args[0], on.hostTime, String(BigInt(on.hostTime) + BigInt(args[1])))) }
    }
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
