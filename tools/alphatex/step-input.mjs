import { unpackMidi } from './session-data.mjs'
import { editProject } from './sequencer-project.mjs'
import { editMidiSourceNotes } from './midi-source.mjs'
import { sourceEditor } from './midi-source-editor.mjs'
import { openMidiInput } from './midi-input.mjs'
import { openStepMonitor } from './step-monitor.mjs'
import { openPracticeTake } from './practice-take.mjs'
import { tickUnits } from './tick-units.mjs'

const inputFailure = reason => reason instanceof Error ? reason : new Error('Step input failed', { cause: reason })
const sourceDocument = editor => editor.project.kind === 'midi-source'
const trackAt = editor => (editor.view ?? editor.project).tracks[editor.track]
// These are editor identities, not rendered labels. A manual decision must not
// move the target of an already held chord, even if it later returns here.
export function sameStepContext(a, b) {
  return a.project === b.project && ['pattern', 'track', 'channel', 'tick', 'pitch',
    'duration', 'step', 'eventView', 'selectedID'].every(key => a[key] === b[key])
}
function target(editor) {
  if (editor.eventView) throw new Error('Return to piano-roll notes before step input')
  const track = trackAt(editor)
  if (!track || (sourceDocument(editor) && !editor.performance)) throw new Error('Select a MIDI pattern before step input')
  const channel = sourceDocument(editor) ? editor.channel ?? (track.channels.length === 1 ? track.channels[0] : undefined) : track.channel
  if (channel === undefined) throw new Error('Select :channel 1–16 before step input')
  return { track, channel }
}
export function stepControl(editor, action) {
  const per = sourceDocument(editor) ? editor.axis.per : editor.project.ppq
  const units = value => tickUnits(value, per, { label: 'Step value' })
  switch (action.kind) {
    case 'step-length': {
      const duration = units(action.value)
      if (duration === 0 && !sourceDocument(editor)) throw new Error('Phrase input length must be positive')
      return { ...editor, duration }
    }
    case 'step-rest': {
      const duration = action.value === undefined ? editor.duration || editor.step : units(action.value)
      const tick = editor.tick + duration
      if (duration <= 0 || !Number.isSafeInteger(tick) || (!sourceDocument(editor) && tick > editor.project.length)) throw new Error('Rest exceeds the document or MIDI tick range')
      return { ...editor, tick, selectedID: undefined }
    }
    default: throw new Error('Unknown step input control')
  }
}
function insertChord(editor, notes) {
  const { track, channel } = target(editor)
  const end = editor.tick + editor.duration
  if (!Number.isSafeInteger(end)) throw new Error('Step input exceeds MIDI tick precision')
  const pitches = new Set(notes.map(note => note.pitch))
  if (pitches.size !== notes.length) throw new Error('Overlapping step notes of the same pitch on one target channel')
  if (sourceDocument(editor)) {
    const port = editor.performance.events.filter(event => event.track === track.sourceTrack && event.tick <= editor.tick
      && event.kind === 'meta' && event.type === 0x21).at(-1)?.data[0] ?? 0
    const overlaps = note => editor.duration === 0
      ? note.duration === 0 ? note.start === editor.tick : note.start <= editor.tick && editor.tick < note.start + note.duration
      : note.duration === 0 ? editor.tick <= note.start && note.start < end : note.start < end && editor.tick < note.start + note.duration
    // SMF tracks can share one physical channel/port, so inspect the selected
    // performance rather than only the target track's notes.
    if (editor.performance.notes.some(note => note.channel === channel && note.port === port && pitches.has(note.pitch) && overlaps(note))) {
      throw new Error('Overlapping step note on the existing source channel/port')
    }
  }
  const changes = notes.map(note => ({ kind: sourceDocument(editor) ? 'insert' : 'note',
    pitch: note.pitch, start: editor.tick, duration: editor.duration, velocity: note.velocity,
    ...(sourceDocument(editor) ? { track: track.sourceTrack, channel, release: note.release } : {}) }))
  const project = sourceDocument(editor) ? editMidiSourceNotes(editor.project, changes, { pattern: editor.pattern })
    : editProject(editor.project, track.id, { kind: 'batch-notes', changes })
  const previous = { ...editor, undo: [...editor.undo, editor.project], redo: [], noteSelection: undefined, selectedID: undefined }
  const next = sourceDocument(editor) ? sourceEditor(project, previous) : { ...previous, project }
  // Source point notes use the positive grid step. A phrase endpoint cursor is
  // retained exactly; further input refuses until the user extends/repositions.
  return { ...next, tick: editor.tick + (editor.duration || editor.step), pitch: notes[0].pitch }
}
// One packet is a private transaction: an unrepresentable message or chord
// cannot leave earlier changes from that packet partly applied.
export function stepPacket(editor, pending, packet) {
  target(editor)
  if (pending && !sameStepContext(pending.context, editor)) throw new Error('Step input context changed while keys were held')
  let state = pending ? { ...pending, notes: pending.notes.map(note => ({ ...note })), held: new Map([...pending.held].map(([key, ids]) => [key, [...ids]])) } : null
  let inserted = 0
  for (const message of unpackMidi(packet)) {
    const type = message[0] >>> 4, status = message[1] >>> 4
    if ((type === 1 && message[1] === 0xff)
        || ([2, 4].includes(type) && status === 0xb && [120, 123].includes(message[2]))) throw new Error('MIDI reset/all-notes-off cancelled step input')
    if (!message.isNoteOn() && !message.isNoteOff()) continue
    const pitch = message[2]
    if (pitch > 127 || (type === 2 && message[3] > 127)) throw new Error('Invalid step-input note data')
    if (type === 4 && (message[3] !== 0 || message[6] !== 0 || message[7] !== 0)) throw new Error('Step notes cannot represent MIDI2 note attributes; use the recorder for raw MIDI')
    const key = JSON.stringify([packet.source, message[0] & 15, message[1] & 15, pitch])
    if (message.isNoteOn()) {
      state ??= { context: editor, notes: [], held: new Map() }
      const ids = state.held.get(key) ?? []
      ids.push(state.notes.length); state.held.set(key, ids)
      // This is an explicit note-editing projection, not raw take recording.
      const velocity = type === 4 ? Math.max(1, ((message[4] << 8) | message[5]) >>> 9) : message[3]
      state.notes.push({ pitch, velocity })
    } else if (state?.held.has(key)) {
      const ids = state.held.get(key), index = ids.shift()
      if (!ids.length) state.held.delete(key)
      const velocity = type === 4 ? ((message[4] << 8) | message[5]) >>> 9 : message[3]
      state.notes[index].release = type === 2 && status === 9 ? { kind: 'note-on-zero' } : { kind: 'note-off', velocity }
      if (!state.held.size) {
        editor = insertChord(editor, state.notes); inserted += state.notes.length; state = null
      }
    }
  }
  return { editor, pending: state, inserted }
}

// The terminal supplies its existing serialized decision queue. Neither stop()
// nor a context cancellation awaits completion inside that queue: an admitted
// packet may itself be waiting to enter the queue.
export function openStepInput({ source, getEditor, adoptEditor, enqueue, onState = () => {},
  audio, practice = false, recording, openTake = openPracticeTake, openMonitor = openStepMonitor, openInput = openMidiInput }) {
  if (practice && !audio) throw new Error('Practice input requires instrument monitoring')
  if (recording && !practice) throw new Error('Practice recording requires live practice mode')
  if (audio) audio = structuredClone(audio)
  const editor = getEditor(), { channel, track } = target(editor)
  if (audio?.sound?.engine?.kind === 'fluidsynth') {
    const tracks = sourceDocument(editor) ? [{ channel, program: 0, level: 100, pan: 64 }] : editor.project.tracks
    audio.initial = tracks.flatMap(track => [[0xc0 | track.channel, track.program],
      [0xb0 | track.channel, 7, track.level], [0xb0 | track.channel, 10, track.pan]])
  }
  const takeContext = recording ? structuredClone({ path: recording.path, project: editor.project, track: track.id, sound: audio.sound, backing: audio.backing }) : null
  const cancellation = new AbortController()
  const stopped = new Error('Step input stopped before arming')
  let pending = null, stopping = false, controlsStopped = false, input = null, failure = null
  let monitor = null, take = null, admission, inputFinal, sealed = false
  const ready = (async () => {
    if (takeContext) take = await openTake(takeContext)
    cancellation.signal.throwIfAborted()
    if (stopping) throw stopped
    monitor = audio ? openMonitor({ ...audio, channel, signal: cancellation.signal }) : null
    monitor?.completion.catch(error => cancellation.abort(inputFailure(error)))
    if (monitor) await monitor.ready
    const renderClock = take ? await monitor.clock : null
    cancellation.signal.throwIfAborted()
    if (stopping) throw stopped
    input = openInput({ source, signal: cancellation.signal, async onPacket(packet, { signal }) {
      if (take) { await admission; await take.append(packet) }
      const prepared = monitor?.prepare(packet)
      await enqueue(() => {
        signal.throwIfAborted()
        if (practice) { onState({ kind: 'input', held: prepared.held.size }); return }
        const result = stepPacket(getEditor(), pending, packet)
        pending = result.pending
        if (result.inserted) adoptEditor(result.editor, result.inserted)
        onState({ kind: 'input', held: pending ? [...pending.held.values()].reduce((n, ids) => n + ids.length, 0) : 0 })
      })
      signal.throwIfAborted()
      if (monitor) await monitor.send(prepared)
    } })
    admission = input.ready.then(async info => {
      if (take) await take.arm(info, renderClock)
      return info
    })
    const info = await admission
    cancellation.signal.throwIfAborted()
    if (stopping) throw stopped
    return { ...info, ...(take ? { recording: take.diagnostics() } : {}), ...(monitor ? { monitoring: true } : {}), ...(practice ? { practice: true } : {}) }
  })()
  ready.catch(() => {})
  const completion = (async () => {
    try { await ready }
    catch (error) {
      if (!(stopping && (error === stopped || !input) && !cancellation.signal.aborted)) { failure = inputFailure(error); cancellation.abort(failure) }
    }
    // A rejected ready acknowledgement does not prove native child closure.
    try { inputFinal = await input?.completion } catch (error) { failure ??= inputFailure(error) }
    monitor?.stop()
    try { await monitor?.completion } catch (error) { failure ??= inputFailure(error) }
    pending = null
    try { await take?.finish({ failure: failure ?? undefined, inputFinal, monitorFinal: monitor?.diagnostics(), signal: cancellation.signal, onCommit() { sealed = true } }) } catch (error) { failure ??= inputFailure(error) }
    sealed = true
    if (failure) throw failure
  })()
  completion.catch(() => {})
  return { kind: practice ? 'practice-input' : 'step-input', ready, completion,
    diagnostics() { return monitor ? { source, ...monitor.diagnostics(), ...(take ? { recording: take.diagnostics() } : {}), failure: failure?.message ?? null } : take ? { source, recording: take.diagnostics(), failure: failure?.message ?? null } : null },
    async inspect() { return monitor ? { source, ...await monitor.inspect(), ...(take ? { recording: take.diagnostics() } : {}), failure: failure?.message ?? null } : take ? { source, recording: take.diagnostics(), failure: failure?.message ?? null } : null },
    stop({ admittedControls = false } = {}) {
      // View close ends native admission immediately, while controls already
      // queued before close must still decide before drained MIDI packets.
      stopping = true
      if (!admittedControls) controlsStopped = true
      input?.stop(); monitor?.stop()
    },
    control(action) {
      if (practice) throw new Error('Stop practice input before changing step-entry controls')
      cancellation.signal.throwIfAborted()
      if (controlsStopped || pending !== null) throw new Error('Release all keys and finish draining before changing step input')
      return stepControl(getEditor(), action)
    },
    cancel(reason = new Error('Step input context changed')) {
      if (sealed) return
      failure ??= inputFailure(reason); cancellation.abort(failure)
    } }
}
