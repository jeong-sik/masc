import { isDeepStrictEqual } from 'node:util'
import { absoluteUmpPitch } from './ump-source.mjs'
import { scaleTicks } from './tick-units.mjs'
import { midiClipPerformance, midiClipNotes, editMidiClip, editMidiClipAttack,
  midiClipHarmony, revoiceMidiClip, clipTick, clipTempo, clipMeter } from './midi-clip-source.mjs'

function expressions(events) {
  return events.filter(event => (event.words[0] >>> 28) === 4 && (event.words[0] >>> 8 & 255) < 128
    && ([0, 1].includes(event.words[0] >>> 20 & 15)
      || [6, 10].includes(event.words[0] >>> 20 & 15) && (event.words[0] & 255) === 0))
}
export function midiClipEditor(project, previous = {}) {
  const performance = midiClipPerformance(project), notes = midiClipNotes(project)
  const events = [...performance.prefix, ...performance.configuration, ...performance.sequence]
  const editor = { undo: [], redo: [], view: notes.length ? 'notes' : 'events', selected: notes[0]?.id ?? events[0]?.id,
    selection: [], ...previous, project, performance, notes, events, expressions: expressions(performance.sequence) }
  const rows = midiClipRows(editor)
  if (!rows.some(row => row.id === editor.selected)) editor.selected = rows[0]?.id
  return editor
}
export const midiClipRows = editor => editor[editor.view]
export const midiClipSelected = editor => midiClipRows(editor).find(row => row.id === editor.selected)
function adopt(editor, project) {
  return isDeepStrictEqual(project, editor.project) ? editor
    : midiClipEditor(project, { ...editor, undo: [...editor.undo, editor.project], redo: [] })
}
export function midiClipAction(editor, action) {
  const rows = midiClipRows(editor)
  switch (action.kind) {
    case 'move': {
      const index = rows.findIndex(row => row.id === editor.selected)
      return { ...editor, selected: rows[Math.max(0, Math.min(rows.length - 1, index + action.direction))]?.id }
    }
    case 'view': {
      if (!['notes', 'expressions', 'events'].includes(action.view)) throw new Error('Unknown MIDI Clip view')
      return midiClipEditor(editor.project, { ...editor, view: action.view })
    }
    case 'undo': case 'redo': {
      const past = editor[action.kind], other = action.kind === 'undo' ? 'redo' : 'undo'
      return past.length ? midiClipEditor(past.at(-1), { ...editor, [action.kind]: past.slice(0, -1),
        [other]: [...editor[other], editor.project] }) : editor
    }
    default: throw new Error('Unknown MIDI Clip action')
  }
}
export function midiClipCommand(editor, line) {
  const [command, ...args] = line.trim().split(/\s+/)
  const count = (min, max = min) => { if (args.length < min || args.length > max) throw new Error(`Wrong arguments for ${command}; use :help`) }
  const selected = () => { const row = midiClipSelected(editor); if (!row) throw new Error('Select a source event'); return row }
  const note = () => { const row = selected(); if (!editor.notes.some(note => note.id === row.id)) throw new Error('Select a native MIDI2 NoteOn'); return row }
  const change = decisions => adopt(editor, editMidiClip(editor.project, decisions))
  const dataWord = text => {
    if (!/^(0|[1-9][0-9]*)$/.test(text) || BigInt(text) > 0xffffffffn) throw new Error('Use an unsigned decimal data word (0–4294967295)')
    return Number(text)
  }
  const group = () => {
    if (!editor.selection.length) throw new Error('Use :select-events ID... to explicitly choose attacks, releases and expression')
    return editor.selection.map(id => editor.events.find(event => event.id === id))
  }
  switch (command) {
    case 'notes': case 'expressions': case 'events': count(0); return { editor: midiClipAction(editor, { kind: 'view', view: command }) }
    case 'select': {
      count(1); const event = editor.events.find(row => row.id === args[0])
      if (!event) throw new Error('Unknown original MIDI Clip byte-offset identity')
      return { editor: { ...editor, view: editor.notes.some(row => row.id === event.id) ? 'notes' : 'events', selected: event.id } }
    }
    case 'select-events': {
      count(1, Number.MAX_SAFE_INTEGER)
      if (new Set(args).size !== args.length || args.some(id => !editor.events.some(row => row.id === id))) throw new Error('Select distinct original MIDI Clip byte offsets')
      return { editor: { ...editor, selection: args } }
    }
    case 'deselect-events': count(0); return { editor: { ...editor, selection: [] } }
    case 'pitch-absolute': case 'velocity': {
      count(1); const values = command === 'pitch-absolute' ? { pitch: absoluteUmpPitch(args[0]) } : { velocity: dataWord(args[0]) }
      return { editor: adopt(editor, editMidiClipAttack(editor.project, note().id, values)) }
    }
    case 'value32': {
      count(1); const row = selected()
      if (!editor.expressions.some(event => event.id === row.id)) throw new Error('Select a native per-note controller, pitch bend or poly pressure')
      return { editor: change([{ kind: 'words', id: row.id, words: [row.words[0], dataWord(args[0])] }]) }
    }
    case 'tempo-value': {
      count(1); const row = selected()
      if (clipTempo(row) === null) throw new Error('Select a MIDI2 Set Tempo event; values use 10ns per quarter note')
      return { editor: change([{ kind: 'words', id: row.id, words: [row.words[0], dataWord(args[0]), 0, 0] }]) }
    }
    case 'meter-value': {
      count(3); const row = selected()
      if (clipMeter(row) === null) throw new Error('Select a MIDI2 Time Signature event')
      const values = args.map(dataWord)
      if (values.some(value => value > 255)) throw new Error('Use the three native 8-bit meter codes')
      return { editor: change([{ kind: 'words', id: row.id, words: [row.words[0], (values[0] * 0x1000000 + values[1] * 0x10000 + values[2] * 0x100) >>> 0, 0, 0] }]) }
    }
    case 'time': count(1); return { editor: change([{ kind: 'time', id: selected().id, tick: args[0] }]) }
    case 'shift-events-ticks': {
      count(1)
      if (!/^(0|-?[1-9][0-9]*)$/.test(args[0])) throw new Error('Use an exact signed tick offset')
      return { editor: change(group().map(row => ({ kind: 'time', id: row.id, tick: String(clipTick(row.tick) + BigInt(args[0])) }))) }
    }
    case 'stretch-events': {
      count(1, 2); const events = group(), anchor = args[1] === undefined
        ? events.reduce((min, row) => clipTick(row.tick) < min ? clipTick(row.tick) : min, clipTick(events[0].tick)) : clipTick(args[1])
      return { editor: change(events.map(row => ({ kind: 'time', id: row.id,
        tick: String(anchor + scaleTicks(clipTick(row.tick) - anchor, args[0])) }))) }
    }
    case 'reset-time': case 'reset-words': count(0); return { editor: change([{ kind: command, id: selected().id }]) }
    case 'reset-event-times': count(0); return { editor: change(group().map(row => ({ kind: 'reset-time', id: row.id }))) }
    case 'revoice': {
      count(2, 4)
      return { editor: adopt(editor, revoiceMidiClip(editor.project, note().id, args[0], {
        mode: args[1], octave: args[2] === undefined ? 4 : Number(args[2]), inversion: args[3] === undefined ? 0 : Number(args[3]) })) }
    }
    case 'harmony': count(0); return { editor, harmony: midiClipHarmony(editor.project, note().id) }
    case 'title': count(1, Number.MAX_SAFE_INTEGER); return { editor: adopt(editor, { ...editor.project, name: args.join(' ') }) }
    case 'undo': case 'redo': count(0); return { editor: midiClipAction(editor, { kind: command }) }
    case 'help': case 'save': case 'play': case 'pause': case 'resume': case 'stop': count(0); return { editor, effect: { kind: command } }
    case 'seek-event': count(0, 1); return { editor, effect: { kind: command, id: args[0] ?? selected().id } }
    case 'initial-tempo': count(0, 1); return { editor, effect: { kind: command, value: args.length ? dataWord(args[0]) : undefined } }
    case 'save-as': case 'export': case 'midi-output': count(1, Number.MAX_SAFE_INTEGER); return { editor,
      effect: { kind: command, path: line.trim().slice(command.length).trimStart() } }
    default: throw new Error('Use :help for native MIDI2 Clip editing commands')
  }
}
