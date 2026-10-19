import { Chord, Note } from 'tonal'
import { midiSourceInfo, midiSourcePattern, editMidiSourceNotes, editMidiSourceExpressions, orderMidiSourceExpression, tempoEvent, editMidiSourceTempos } from './midi-source.mjs'
import { expressionEvent } from './midi-expression.mjs'
import { pitch, chordVoicing } from './sequencer-project.mjs'

export function sourceEditor(project, previous = {}, pattern = previous.pattern) {
  const info = midiSourceInfo(project)
  if (pattern !== undefined && (!Number.isSafeInteger(pattern) || pattern < 0 || pattern >= info.patterns)) throw new Error('Unknown MIDI pattern')
  const chosen = info.format === 2 && info.patterns > 1 ? pattern : 0
  const performance = chosen === undefined ? null : midiSourcePattern(project, { pattern: chosen })
  const per = info.timing.kind === 'ppq' ? info.timing.ppq : info.timing.ticksPerFrame
  const axis = { per, label: info.timing.kind === 'ppq' ? 'beats' : 'frames' }
  const indexes = info.format === 2 ? chosen === undefined ? [] : [chosen] : info.tracks.map(t => t.index)
  const tracks = indexes.map(index => {
    const notes = performance.notes.filter(note => note.track === index)
    const channels = [...new Set(performance.events.filter(e => e.track === index && e.kind === 'channel').map(e => e.bytes[0] & 15))]
    return { id: String(index), sourceTrack: index, name: info.tracks[index].name, notes, channels,
      detail: `${channels.map(c => c+1).join(', ') || 'no'} MIDI channels · source track ${index+1}`, muted: false, solo: false }
  })
  if (!tracks.length) tracks.push({ id: 'pattern-choice', name: `Choose :pattern 1–${info.patterns}`, detail: 'Independent SMF patterns', notes: [], channels: [], muted: false, solo: false })
  const firstTempo = performance?.events.filter(e => e.kind === 'meta' && e.type === 0x51 && e.tick === 0).at(-1)
  const tempo = firstTempo ? tempoEvent(firstTempo).value : 120
  const meter = performance?.events.find(e => e.kind === 'meta' && e.type === 0x58 && e.tick === 0 && e.data.length === 4)
  const end = performance?.ticks ?? 0
  const length = end + 1 // include endpoint notes in the viewport, without extending the source performance
  const view = { title: project.name, tempo, meter: meter ? [meter.data[0], 2 ** meter.data[1]] : [4,4],
    timingLabel: info.timing.kind === 'ppq' ? 'MIDI tempo map' : `SMPTE ${info.timing.frameCode}`,
    displayLength: end, length, loop: { start: 0, end }, tracks }
  const steps = [per/4,per/2,per,per*2,per*4].filter(n => Number.isSafeInteger(n) && n > 0)
  const track = Math.min(previous.track ?? Math.max(0, tracks.findIndex(t => t.notes.length)), tracks.length-1)
  const first = tracks[track].notes.reduce((first, note) =>
    first === null || note.start < first.start ? note : first, null)
  return { velocity: 96, duration: per, step: steps[0], undo: [], redo: [], ...previous,
    project, pattern: chosen, performance, info, axis, view, steps,
    selectedID: performance?.notes.some(n=>n.id===previous.selectedID) ? previous.selectedID : undefined,
    selectedExpressionID: performance?.events.some(event=>event.id===previous.selectedExpressionID && expressionEvent(event)) ? previous.selectedExpressionID : undefined,
    selectedTempoID: performance?.events.some(event=>event.id===previous.selectedTempoID && tempoEvent(event)) ? previous.selectedTempoID : undefined,
    track,
    tick: Math.min(previous.tick ?? first?.start ?? 0, length-1),
    pitch: previous.pitch ?? first?.pitch ?? 60 }
}
function atCursor(editor) {
  return editor.view.tracks[editor.track].notes.filter(n => n.pitch === editor.pitch
    && (editor.channel === undefined || n.channel === editor.channel)
    && (n.duration === 0 ? n.start === editor.tick : n.start <= editor.tick && editor.tick < n.start+n.duration))
}
export function sourceSelected(editor) {
  const notes=atCursor(editor)
  return editor.selectedID ? notes.find(n=>n.id===editor.selectedID) : notes.length===1 ? notes[0] : undefined
}
function apply(editor, edits) {
  const project = editMidiSourceNotes(editor.project, edits, { pattern: editor.pattern })
  return sourceEditor(project, { ...editor, undo: [...editor.undo,editor.project], redo: [] })
}
export function sourceExpressions(editor) {
  const track = editor.view.tracks[editor.track].sourceTrack
  return (editor.performance?.events ?? []).flatMap(event => {
    const value = expressionEvent(event)
    return value && value.track === track && (editor.channel === undefined || value.channel === editor.channel) ? [value] : []
  })
}
export const selectedExpression = editor => sourceExpressions(editor).find(event => event.id === editor.selectedExpressionID)
export const sourceTempos = editor => (editor.performance?.events ?? []).flatMap(event => {
  const tempo = tempoEvent(event)
  return tempo ? [tempo] : []
})
export const selectedTempo = editor => sourceTempos(editor).find(event => event.id === editor.selectedTempoID)
function applyTempos(editor, edits) {
  const project = editMidiSourceTempos(editor.project, edits, { pattern: editor.pattern })
  return sourceEditor(project, { ...editor, undo: [...editor.undo, editor.project], redo: [] })
}
function tempoSelection(editor) {
  const event = selectedTempo(editor)
  if (!event) throw new Error('Select a tempo event with :tempos, Up/Down or :tempo-event ID')
  return event
}
function applyExpressions(editor, edits) {
  const project = editMidiSourceExpressions(editor.project, edits, { pattern: editor.pattern })
  return sourceEditor(project, { ...editor, undo: [...editor.undo, editor.project], redo: [] })
}
function expressionSelection(editor) {
  const event = selectedExpression(editor)
  if (!event) throw new Error('Select an expression event with :events, Up/Down or :event ID')
  return event
}
function insertion(editor, data) {
  const track = editor.view.tracks[editor.track]
  const channel = editor.channel ?? (track.channels.length === 1 ? track.channels[0] : undefined)
  if (channel === undefined) throw new Error('Select :channel 1–16 before inserting into this source track')
  return { kind:'insert', track:track.sourceTrack, channel, ...data }
}
export function sourceAction(editor, action) {
  const note = sourceSelected(editor)
  if (['toggle-note','remove','move-note','duration','velocity'].includes(action.kind) && !note && atCursor(editor).length>1) throw new Error('Several source notes share the cursor; use :channel or :select event-ID')
  switch (action.kind) {
    case 'tempo-next': {
      const events = sourceTempos(editor)
      if (!events.length) return { ...editor, selectedTempoID: undefined }
      const index = events.findIndex(event => event.id === editor.selectedTempoID)
      const event = events[index < 0 ? action.direction > 0 ? 0 : events.length - 1 : (index + action.direction + events.length) % events.length]
      return { ...editor, selectedTempoID: event.id, tick: event.tick, track: editor.view.tracks.findIndex(track => track.sourceTrack === event.track) }
    }
    case 'tempo-remove': return applyTempos(editor, [{ kind: 'remove', id: tempoSelection(editor).id }])
    case 'tempo-move': {
      const event = tempoSelection(editor), tick = event.tick + action.ticks
      return { ...applyTempos(editor, [{ kind: 'change', id: event.id, tick }]), tick }
    }
    case 'tempo-value': {
      const event = tempoSelection(editor)
      return applyTempos(editor, [{ kind: 'change', id: event.id, value: action.value ?? event.value + action.delta }])
    }
    case 'expression-next': {
      const events = sourceExpressions(editor)
      if (!events.length) return { ...editor, selectedExpressionID: undefined }
      const index = events.findIndex(event => event.id === editor.selectedExpressionID)
      const event = events[index < 0 ? action.direction > 0 ? 0 : events.length - 1 : (index + action.direction + events.length) % events.length]
      return { ...editor, selectedExpressionID: event.id, tick: event.tick }
    }
    case 'expression-remove': return applyExpressions(editor, [{ kind: 'remove', id: expressionSelection(editor).id }])
    case 'expression-move': {
      const event = expressionSelection(editor), tick = event.tick + action.ticks
      return { ...applyExpressions(editor, [{ kind: 'change', id: event.id, tick }]), tick }
    }
    case 'expression-value': {
      const event = expressionSelection(editor)
      return applyExpressions(editor, [{ kind: 'change', id: event.id, message: { ...event, value: action.value ?? event.value + action.delta } }])
    }
    case 'move': return { ...editor, selectedID:undefined, tick:Math.max(0,Math.min(editor.view.length-1,editor.tick+(action.ticks??0))),pitch:Math.max(0,Math.min(127,editor.pitch+(action.pitches??0))) }
    case 'track': return { ...editor,track:(editor.track+1)%editor.view.tracks.length,channel:undefined,selectedID:undefined,selectedExpressionID:undefined,selectedTempoID:undefined }
    case 'toggle-note': return apply(editor,[note ? {id:note.id,kind:'remove'} : insertion(editor,{pitch:editor.pitch,start:editor.tick,duration:editor.duration,velocity:editor.velocity})])
    case 'remove': if (!note) throw new Error('No MIDI note at cursor'); return apply(editor,[{id:note.id,kind:'remove'}])
    case 'move-note': {
      if (!note) throw new Error('No MIDI note at cursor')
      const changed=apply(editor,[{id:note.id,start:note.start+(action.ticks??0),pitch:note.pitch+(action.pitches??0)}])
      return {...changed,tick:editor.tick+(action.ticks??0),pitch:editor.pitch+(action.pitches??0)}
    }
    case 'duration': {
      if (!Number.isSafeInteger(action.value)||action.value<0) throw new Error('Invalid source note duration')
      return {...(note?apply(editor,[{id:note.id,duration:action.value}]):editor),duration:action.value}
    }
    case 'velocity': {
      const velocity=Math.max(1,Math.min(127,action.value))
      return {...(note?apply(editor,[{id:note.id,velocity}]):editor),velocity}
    }
    case 'grid': return {...editor,step:editor.steps[(editor.steps.indexOf(editor.step)+1)%editor.steps.length]}
    case 'undo': case 'redo': {
      const past=editor[action.kind];if(!past.length)return editor
      const other=action.kind==='undo'?'redo':'undo'
      return sourceEditor(past.at(-1),{...editor,[action.kind]:past.slice(0,-1),[other]:[...editor[other],editor.project]})
    }
    default: throw new Error('This source action needs the MIDI arrangement/event editor')
  }
}
export function sourceCommand(editor,line) {
  const [command,...args]=line.trim().split(/\s+/)
  const count=(low,high=low)=>{if(args.length<low||args.length>high)throw new Error(`Wrong arguments for ${command}`)}
  const units=value=>{const n=Number(value)*editor.axis.per;if(!Number.isSafeInteger(n)||n<0)throw new Error(`Position must resolve to source ticks (${editor.axis.label})`);return n}
  const notes=editor.view.tracks[editor.track].notes
  const message = (kind, values, channel) => {
    const expected = ['cc','poly-pressure'].includes(kind) ? 2 : 1
    if (values.length !== expected) throw new Error('Expression value arguments do not match its message kind')
    return { kind, channel, value: Number(values.at(-1)), ...(kind === 'cc' ? { controller: Number(values[0]) } : {}),
      ...(kind === 'poly-pressure' ? { pitch: pitch(values[0]) } : {}) }
  }
  switch(command){
    case 'tempos': {
      count(0); const next = { ...editor, eventView: editor.eventView === 'tempo' ? undefined : 'tempo' }
      return { editor: next.eventView && !selectedTempo(next) ? sourceAction(next, { kind: 'tempo-next', direction: 1 }) : next }
    }
    case 'tempo-event': {
      count(1); const value = sourceTempos(editor).find(event => event.id === args[0])
      if (!value) throw new Error('Choose a tempo event in the selected pattern')
      return { editor: { ...editor, eventView: 'tempo', selectedTempoID: value.id, tick: value.tick,
        track: editor.view.tracks.findIndex(track => track.sourceTrack === value.track) } }
    }
    case 'tempo-value': count(1); return { editor: sourceAction(editor, { kind: 'tempo-value', value: Number(args[0]) }) }
    case 'tempo-move': count(1); return { editor: sourceAction(editor, { kind: 'tempo-move', ticks: units(args[0]) - tempoSelection(editor).tick }) }
    case 'tempo-remove': count(0); return { editor: sourceAction(editor, { kind: 'tempo-remove' }) }
    case 'tempo': {
      count(1,2); const tick = args[1] === undefined ? editor.tick : units(args[1])
      const existing = sourceTempos(editor).filter(event => event.tick === tick)
      if (existing.length > 1) throw new Error('Several tempo events share this tick; select :tempo-event ID and use :tempo-value')
      const next = applyTempos(editor, [existing.length ? { kind: 'change', id: existing[0].id, value: Number(args[0]) }
        : { kind: 'insert', tick, value: Number(args[0]) }])
      return { editor: { ...next, eventView: 'tempo', selectedTempoID: existing[0]?.id ?? next.project.insertions.at(-1).id, tick } }
    }
    case 'events': {
      count(0); const next = { ...editor, eventView: editor.eventView === 'expression' ? undefined : 'expression' }
      return { editor: next.eventView && !selectedExpression(next) ? sourceAction(next, { kind: 'expression-next', direction: 1 }) : next }
    }
    case 'event': {
      count(1); const event = editor.performance?.events.find(event => event.id === args[0]), value = expressionEvent(event)
      if (!value) throw new Error('Choose an expression event in the selected pattern')
      return { editor: { ...editor, eventView: 'expression', selectedExpressionID: value.id, tick: value.tick,
        track: editor.view.tracks.findIndex(track => track.sourceTrack === value.track), channel: value.channel } }
    }
    case 'event-value': count(1); return { editor: sourceAction(editor, { kind: 'expression-value', value: Number(args[0]) }) }
    case 'event-move': count(1); return { editor: sourceAction(editor, { kind: 'expression-move', ticks: units(args[0]) - expressionSelection(editor).tick }) }
    case 'event-remove': count(0); return { editor: sourceAction(editor, { kind: 'expression-remove' }) }
    case 'event-before': case 'event-order-reset': {
      count(command === 'event-before' ? 1 : 0)
      const event = expressionSelection(editor)
      const before = command === 'event-order-reset' ? null : args[0] === 'first-note'
        ? editor.performance.events.find(value => value.track === event.track && value.tick === event.tick
          && value.kind === 'channel' && value.bytes[0] === (0x90 | event.channel) && value.bytes[2] > 0)?.id
        : args[0]
      const project = orderMidiSourceExpression(editor.project, { id: event.id, before }, { pattern: editor.pattern })
      return { editor: sourceEditor(project, { ...editor, undo: [...editor.undo,editor.project], redo: [] }) }
    }
    case 'event-set': {
      count(2,3);const event=expressionSelection(editor)
      return {editor:applyExpressions(editor,[{kind:'change',id:event.id,message:message(args[0],args.slice(1),event.channel)}])}
    }
    case 'event-channel': {
      count(1);const event=expressionSelection(editor)
      const channel=Number(args[0])-1
      return {editor:{...applyExpressions(editor,[{kind:'change',id:event.id,message:{...event,channel}}]),channel}}
    }
    case 'cc': case 'bend': case 'program': case 'pressure': case 'poly-pressure': {
      const values = ['cc','poly-pressure'].includes(command) ? 2 : 1;count(values,values+1)
      const track = editor.view.tracks[editor.track]
      const channel = editor.channel ?? (track.channels.length === 1 ? track.channels[0] : undefined)
      if (channel === undefined) throw new Error('Select :channel 1–16 before inserting expression events')
      const tick = args[values] === undefined ? editor.tick : units(args[values])
      const next = applyExpressions(editor, [{ kind:'insert',track:track.sourceTrack,tick,message:message(command,args.slice(0,values),channel) }])
      return { editor: { ...next, eventView:'expression', selectedExpressionID:next.project.insertions.at(-1).id,tick } }
    }
    case 'pattern':{
      count(1);const pattern=Number(args[0])-1
      if(!Number.isSafeInteger(pattern)||pattern<0||pattern>=editor.info.patterns)throw new Error('Unknown MIDI pattern')
      return {editor:sourceEditor(editor.project,{...editor,track:0,tick:undefined,pitch:undefined,selectedID:undefined,channel:undefined,selectedExpressionID:undefined,selectedTempoID:undefined},pattern)}
    }
    case 'select':{
      count(1);const note=editor.performance?.notes.find(n=>n.id===args[0]);if(!note)throw new Error('Unknown MIDI note event ID')
      const track=editor.view.tracks.findIndex(t=>t.sourceTrack===note.track)
      return {editor:{...editor,eventView:undefined,selectedID:note.id,track,tick:note.start,pitch:note.pitch,channel:note.channel,selectedExpressionID:undefined,selectedTempoID:undefined}}
    }
    case 'channel':{
      count(1);const channel=Number(args[0])-1
      if(!Number.isSafeInteger(channel)||channel<0||channel>15)throw new Error('MIDI channel must be 1–16')
      return {editor:{...editor,channel,selectedID:undefined,selectedExpressionID:undefined}}
    }
    case 'track':{
      count(1);const track=Number(args[0])-1
      if(!Number.isSafeInteger(track)||track<0||track>=editor.view.tracks.length)throw new Error('Unknown MIDI track')
      return {editor:{...editor,track,channel:undefined,selectedID:undefined,selectedExpressionID:undefined,selectedTempoID:undefined}}
    }
    case 'note':{
      count(3,4)
      return {editor:apply(editor,[insertion(editor,{pitch:pitch(args[0]),start:units(args[1]),duration:units(args[2]),velocity:args[3]===undefined?editor.velocity:Number(args[3])})])}
    }
    case 'chord':{
      count(3,6)
      const values=chordVoicing(args[0],{mode:args[3]??'close',octave:args[4]===undefined?4:Number(args[4]),inversion:args[5]===undefined?0:Number(args[5])})
      return {editor:apply(editor,values.map(value=>insertion(editor,{pitch:value,start:units(args[1]),duration:units(args[2]),velocity:editor.velocity})))}
    }
    case 'progression':{
      count(4,Number.MAX_SAFE_INTEGER)
      const start=units(args[0]),duration=units(args[1]),edits=[];let previous=[]
      for(const [i,symbol] of args.slice(3).entries()){
        previous=chordVoicing(symbol,{mode:args[2],octave:3,previous})
        for(const value of previous)edits.push(insertion(editor,{pitch:value,start:start+i*duration,duration,velocity:editor.velocity}))
      }
      return {editor:apply(editor,edits)}
    }
    case 'transpose':{
      count(1);const semitones=Number(args[0]);if(!Number.isSafeInteger(semitones))throw new Error('Invalid transposition')
      return {editor:apply(editor,notes.map(n=>({id:n.id,pitch:n.pitch+semitones})))}
    }
    case 'quantize':{
      count(1);const grid=units(args[0]);if(!grid)throw new Error('Grid must be positive')
      return {editor:apply(editor,notes.map(n=>({id:n.id,start:Math.round(n.start/grid)*grid})))}
    }
    case 'duplicate':{
      count(1);const offset=units(args[0])
      // An inserted note normally takes the active port at its new position.
      // Duplication must retain the selected source note's routing instead.
      const portAt=(track,tick)=>editor.performance.events.filter(e=>e.track===track&&e.tick<=tick&&e.kind==='meta'&&e.type===0x21).at(-1)?.data[0]??0
      if(notes.some(n=>portAt(n.track,n.start+offset)!==n.port||portAt(n.track,n.start+offset+n.duration)!==n.port)){
        throw new Error('Duplicate changes the source port; explicit route edits are not supported')
      }
      return {editor:apply(editor,notes.map(n=>({kind:'insert',track:n.track,channel:n.channel,pitch:n.pitch,start:n.start+offset,duration:n.duration,velocity:n.velocity})))}
    }
    case 'cursor':{
      count(2);const tick=units(args[0]);if(tick>=editor.view.length)throw new Error('Cursor outside MIDI source')
      return {editor:{...editor,tick,pitch:pitch(args[1]),selectedID:undefined}}
    }
    case 'title':count(1,Number.MAX_SAFE_INTEGER);return {editor:sourceEditor({...editor.project,name:args.join(' ')},{...editor,undo:[...editor.undo,editor.project],redo:[]})}
    case 'undo':case 'redo':count(0);return {editor:sourceAction(editor,{kind:command})}
    case 'save':case 'play':case 'stop':case 'record':case 'help':case 'audio':count(0);return {editor,effect:{kind:command}}
    case 'save-as':case 'export':case 'wave':case 'output':case 'midi-output':count(1,Number.MAX_SAFE_INTEGER);return {editor,effect:{kind:command,path:args.join(' ')}}
    case 'midi-port':count(2);{
      const port=Number(args[0]);if(!Number.isInteger(port)||port<0||port>127)throw new Error('MIDI port must be 0–127')
      return {editor,effect:{kind:'midi-port',port,destination:args[1]}}
    }
    case 'seek':count(1);return {editor,effect:{kind:'seek',tick:units(args[0])}}
    default:throw new Error('Unsupported source command; use :help for source note, expression and tempo editing')
  }
}
export function sourceHarmony(editor) {
  const notes=editor.view.tracks.flatMap(t=>t.notes).filter(n=>n.start<=editor.tick&&editor.tick<n.start+n.duration)
  const pitches=[...new Set(notes.map(n=>n.pitch))].sort((a,b)=>a-b)
  return {pitches,notes:pitches.map(Note.fromMidi),candidates:Chord.detect(pitches.map(Note.fromMidi))}
}
