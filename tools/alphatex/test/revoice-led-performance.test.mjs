import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { once } from 'node:events'
import { Worker } from 'node:worker_threads'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { newProject, editProject, PPQ } from '../sequencer-project.mjs'
import { newEditor, editorCommand, editorAction, selectedNote } from '../sequencer-editor.mjs'
import { midiSourcePattern, importMidiSource } from '../midi-source.mjs'
import { saveProject, loadProject, projectMidi } from '../sequencer-files.mjs'
import { arrangementFromPhrase, phraseDocument } from '../phrase-arrangement.mjs'
midiFiles(JZZ)

const command = (editor, line) => editorCommand(editor, line).editor
const symbols = 'G7 Em7 Cmaj7 G7#11'
// Independent Tonal left-hand dictionary paths: global motion31, versus the
// best greedy-from-each-start path35 (the existing progression oracle fixture).
const expected = [[53,57,59,64], [55,59,62,66], [52,55,59,62], [53,57,61,65]]
const pitches = [60,64,67,71], starts = [0, 2, 5, 8]
function phrase() {
  let project = newProject()
  for (const start of starts) for (const [voice, key] of pitches.entries()) {
    project = editProject(project, 'track-1', { kind: 'note', pitch: key, start: start * PPQ,
      duration: (4 - voice) * 120, velocity: 70 + voice + start })
  }
  project = editProject(project, 'track-1', { kind: 'note', pitch: 24, start: 12 * PPQ, duration: PPQ, velocity: 91 })
  project = editProject(project, 'track-1', { kind: 'track', name: 'Bass' })
  return editProject(project, 'track-2', { kind: 'note', pitch: 36, start: 0, duration: PPQ, velocity: 85 })
}
const rows = notes => starts.map(start => notes.filter(note => note.start === start * PPQ).sort((a, b) => a.pitch - b.pitch).map(note => note.pitch))

test('existing rhythmic phrase is revoiced globally in one revision; identities, gaps and releases survive direct consumers', async () => {
  const project = phrase(), before = structuredClone(project)
  let editor = command(newEditor(project), 'cursor 2 E4')
  const selected = selectedNote(editor).id
  editor = command(editor, `revoice-led 0 10 rootless C3 C5 ${symbols}`)
  assert.equal(editor.undo.length, 1); assert.equal(selectedNote(editor).id, selected)
  const notes = editor.project.tracks[0].notes
  assert.deepEqual(rows(notes), expected)
  for (const original of before.tracks[0].notes) {
    const { pitch, ...rest } = original, { pitch: afterPitch, ...after } = notes.find(note => note.id === original.id)
    assert.deepEqual(after, rest)
    if (original.start >= 10 * PPQ) assert.equal(afterPitch, pitch)
  }
  assert.deepEqual(editor.project.tracks[1], before.tracks[1]); assert.deepEqual(project, before)
  const changed = editor.project
  editor = editorAction(editor, { kind: 'undo' }); assert.deepEqual(editor.project, before); assert.equal(selectedNote(editor).id, selected)
  editor = editorAction(editor, { kind: 'redo' }); assert.deepEqual(editor.project, changed); assert.equal(selectedNote(editor).id, selected)
  const root = await mkdtemp(join(tmpdir(), 'masc-revoice-led-')), worker = new Worker(new URL('../sequencer-worker.mjs', import.meta.url))
  try {
    const path = join(root, 'phrase.json'); await saveProject(path, editor.project)
    const reopened = (await loadProject(path)).project; assert.deepEqual(reopened, changed)
    const parsed = new JZZ.MIDI.SMF(projectMidi(reopened)), on = [...parsed[1]].filter(event => event.isNoteOn())
    assert.deepEqual(on.map(event => [event.tt,event[1],event[2]]), notes.map(note => [note.start,note.pitch,note.velocity]))
    const arranged = arrangementFromPhrase(reopened)
    assert.deepEqual(phraseDocument(arranged.project, arranged.project.assets[0].id), reopened)
    const reply = once(worker, 'message')
    worker.postMessage({ id: 1, project: reopened, cancel: new SharedArrayBuffer(4), options: { format: 'harmony', scope: { kind: 'track', id: 'track-1' } } })
    const result = (await reply)[0]; assert.equal(result.ok, true)
    for (const [i, start] of starts.entries()) assert.deepEqual(result.result.rows.find(row => row.start === start * PPQ).pitches, expected[i])
  } finally { await worker.terminate(); await rm(root, { recursive: true, force: true }) }
})

function source({ division = 1001, format = 0, channels = [0], ports = [3], unsafe, overlap = false, point = false } = {}) {
  const file = division < 0 ? new JZZ.MIDI.SMF(format, -division, 80) : new JZZ.MIDI.SMF(format, division)
  const per = division < 0 ? 80 : division, track = new JZZ.MIDI.SMF.MTrk(), events = []
  track.add(0, JZZ.MIDI.smfBPM(120)).add(per * 3, JZZ.MIDI.smfBPM(77))
  for (const port of ports) {
    const add = (tick, message) => events.push({ tick, port, message })
    add(0, JZZ.MIDI.control(0, 1, port))
    for (const channel of channels) {
      add(0, JZZ.MIDI.program(channel, 33)); add(0, JZZ.MIDI.pitchBend(channel, 9001))
      for (const [index, start] of starts.entries()) for (const [voice, key] of pitches.entries()) {
        add(start * per, JZZ.MIDI.noteOn(channel, key, 70 + voice + index))
        const end = (start + (overlap && index === 0 ? 3 : (4 - voice) / 8)) * per
        // Use integer source ticks while varying release order and form.
        const at = point ? start * per : Math.floor(end)
        add(at, voice === 1 ? JZZ.MIDI.noteOn(channel, key, 0) : JZZ.MIDI.noteOff(channel, key, 30 + voice))
      }
      add(per, JZZ.MIDI.aftertouch(channel, 60, 44))
    }
  }
  if (unsafe === 'unclosed') events.push({ tick: per, port: ports[0], message: JZZ.MIDI.noteOn(0, 79, 80) })
  if (unsafe === 'unmatched') events.push({ tick: per, port: ports[0], message: JZZ.MIDI.noteOff(0, 79, 80) })
  let previous
  for (const event of events.sort((a, b) => a.tick - b.tick || a.port - b.port)) {
    if (!previous || previous.tick !== event.tick || previous.port !== event.port) {
      // JZZ's fixture serializer otherwise retains running status across meta.
      // The explicit different channel status makes each port block valid SMF.
      track.add(event.tick, JZZ.MIDI.smfMidiPort(event.port)).add(event.tick, JZZ.MIDI.pressure(15, 0))
    }
    track.add(event.tick, event.message); previous = event
  }
  track.add(12 * per, JZZ.MIDI.smfEndOfTrack()); file.push(track)
  if (format === 2) file.push(new JZZ.MIDI.SMF.MTrk().add(0, JZZ.MIDI.noteOn(1, 36, 77)).add(per, JZZ.MIDI.noteOff(1, 36, 55)).add(12 * per, JZZ.MIDI.smfEndOfTrack()))
  return importMidiSource(file.toUint8Array())
}

for (const division of [1001, -29]) test(`source revoicing preserves native ${division === 1001 ? 'PPQ' : 'drop-frame SMPTE'} ticks and every non-note event through actual export/reopen`, async () => {
  const original = source({ division }), before = midiSourcePattern(original)
  let editor = newEditor(original), voice = before.notes.find(note => note.start === 0 && note.pitch === 64)
  editor = command(editor, `select ${voice.id}`)
  editor = command(editor, `revoice-led 0 10 rootless C3 C5 ${symbols}`)
  assert.equal(selectedNote(editor).id, voice.id)
  const after = editor.performance, noteEvents = new Set(before.notes.flatMap(note => [note.id, note.off]))
  for (const note of before.notes) {
    const { pitch, ...rest } = note, { pitch: afterPitch, ...next } = after.notes.find(value => value.id === note.id)
    assert.deepEqual(next, rest)
    const index = pitches.indexOf(pitch), group = starts.indexOf(note.start / editor.axis.per)
    assert.equal(afterPitch, expected[group][index])
  }
  assert.deepEqual(after.events.filter(event => !noteEvents.has(event.id)), before.events.filter(event => !noteEvents.has(event.id)))
  assert.equal(editor.project.original, original.original)
  assert.equal(editor.undo.length, 1)
  const changed = editor.project
  editor = editorAction(editor, { kind: 'undo' }); assert.deepEqual(editor.project, original); assert.equal(selectedNote(editor).id, voice.id)
  editor = editorAction(editor, { kind: 'redo' }); assert.deepEqual(editor.project, changed)
  const root = await mkdtemp(join(tmpdir(), 'masc-revoice-led-source-'))
  try {
    const path = join(root, 'source.json'), originalPath = join(root, 'original.mid')
    await writeFile(originalPath, Buffer.from(original.original, 'base64'))
    await saveProject(path, changed); const reopened = (await loadProject(path)).project
    const exported = midiSourcePattern(importMidiSource(projectMidi(reopened)))
    assert.deepEqual(exported.timing, before.timing)
    assert.deepEqual(exported.notes.map(({ id, off, ...note }) => note), after.notes.map(({ id, off, ...note }) => note))
    assert.deepEqual(exported.events.map(({ id, order, ...event }) => event), after.events.map(({ id, order, ...event }) => event))
    assert.deepEqual(await readFile(originalPath), Buffer.from(original.original, 'base64'))
  } finally { await rm(root, { recursive: true, force: true }) }
})

test('channel, exact source port anchor, format2 and stale selection require explicit routing decisions', () => {
  let editor = newEditor(source({ channels: [0, 1] }))
  assert.throws(() => command(editor, `revoice-led 0 10 rootless C3 C5 ${symbols}`), /channels/)
  editor = command(editor, 'channel 1')
  const other = editor.performance.notes.filter(note => note.channel === 1)
  editor = command(editor, `revoice-led 0 10 rootless C3 C5 ${symbols}`)
  assert.deepEqual(editor.performance.notes.filter(note => note.channel === 1), other)
  editor = newEditor(source({ ports: [1, 2] }))
  assert.throws(() => command(editor, `revoice-led 0 10 rootless C3 C5 ${symbols}`), /ports/)
  const anchor = editor.performance.notes.find(note => note.port === 2 && note.pitch === 64 && note.start === 0)
  editor = command(editor, `select ${anchor.id}`)
  const untouched = editor.performance.notes.filter(note => note.port === 1)
  editor = command(editor, `revoice-led 0 10 rootless C3 C5 ${symbols}`)
  assert.deepEqual(editor.performance.notes.filter(note => note.port === 1), untouched)
  assert.equal(selectedNote(editor).id, anchor.id)
  const stale = { ...editor, tick: 1001 }
  assert.throws(() => command(stale, `revoice-led 0 10 rootless C3 C5 ${symbols}`), /anchor again/)
  const original = source({ format: 2 })
  editor = newEditor(original)
  assert.throws(() => command(editor, `revoice-led 0 10 rootless C3 C5 ${symbols}`), /pattern/)
  editor = command(editor, 'pattern 1')
  const second = new JZZ.MIDI.SMF(projectMidi(original))[1].dump()
  editor = command(editor, `revoice-led 0 10 rootless C3 C5 ${symbols}`)
  assert.equal(new JZZ.MIDI.SMF(projectMidi(editor.project))[1].dump(), second)
})

test('unsafe ranges, changing group counts, malformed voicings and drum channels leave source/phrase history intact', () => {
  for (const editor of [newEditor(phrase()), newEditor(source())]) {
    for (const line of ['revoice-led 0 0 rootless C3 C5 G7', 'revoice-led 0 10 rootless C3 C5 G7',
      `revoice-led 0 10 close C5 C3 ${symbols}`, `revoice-led 0 10 rootless C3 C3 ${symbols}`,
      `revoice-led 0 10 unknown C3 C5 ${symbols}`, 'revoice-led 0 10 close C3 C5 C C C C',
      `revoice-led 0 17 rootless C3 C5 ${symbols}`]) {
      const before = structuredClone(editor); assert.throws(() => command(editor, line), line); assert.deepEqual(editor, before)
    }
  }
  for (const options of [{ unsafe: 'unclosed' }, { unsafe: 'unmatched' }, { overlap: true }, { channels: [9] }]) {
    const editor = newEditor(source(options)), before = structuredClone(editor)
    assert.throws(() => command(editor, `revoice-led 0 10 rootless C3 C5 ${symbols}`)); assert.deepEqual(editor, before)
  }
  let editor = newEditor(editProject(phrase(), 'track-1', { kind: 'drum-track', name: 'Drums' }))
  editor = command(editor, 'track 3'); const before = structuredClone(editor)
  assert.throws(() => command(editor, 'revoice-led 0 10 close C3 C5 C'), /melodic track/); assert.deepEqual(editor, before)
})

test('half-open onset selection preserves prior tails and final releases; source point notes remain points', () => {
  const initial = phrase(); initial.tracks[0].notes[0].pitch = 59; initial.tracks[0].notes[0].duration = 3 * PPQ
  let editor = newEditor(initial), before = structuredClone(editor.project)
  editor = command(editor, 'revoice-led 2 8 close C3 C5 Dm7 G7')
  for (const note of before.tracks[0].notes.filter(note => note.start < 2 * PPQ || note.start >= 8 * PPQ)) {
    assert.deepEqual(editor.project.tracks[0].notes.find(value => value.id === note.id), note)
  }
  editor = newEditor(source({ point: true }))
  editor = command(editor, `revoice-led 0 10 rootless C3 C5 ${symbols}`)
  assert.equal(editor.performance.notes.length, 16); assert.ok(editor.performance.notes.every(note => note.duration === 0))
  const project = phrase(); project.tracks[0].notes.find(note => note.start === 8 * PPQ).duration = 3 * PPQ
  editor = command(newEditor(project), `revoice-led 0 9 rootless C3 C5 ${symbols}`)
  assert.equal(editor.project.tracks[0].notes.find(note => note.start === 8 * PPQ).duration, 3 * PPQ)
  // A valid performance with a tail beyond the next selected onset is refused
  // without guessing which chord owns that held voice.
  project.tracks[0].notes[0].duration = 3 * PPQ
  project.tracks[0].notes[0].pitch = 59
  editor = newEditor(project); const original = structuredClone(editor)
  assert.throws(() => command(editor, `revoice-led 0 10 rootless C3 C5 ${symbols}`), /overlap the next onset/)
  assert.deepEqual(editor, original)
})

test('three-voice recorded shapes retain their count and changing onset counts refuse the whole revision', () => {
  const project = phrase(); project.tracks[0].notes = project.tracks[0].notes.filter(note => note.pitch !== 71)
  const editor = newEditor(project), changed = command(editor, 'revoice-led 0 10 rootless C3 C5 G7#9 G7#9 G7#9 G7#9')
  assert.equal(changed.project.tracks[0].notes.length, project.tracks[0].notes.length)
  // G7#9 left-hand dictionary is major3/minor7/augmented9: B3/F4/Bb4.
  for (const start of starts) assert.deepEqual(changed.project.tracks[0].notes.filter(note => note.start === start * PPQ).map(note => note.pitch), [59, 65, 70])
  const unequal = structuredClone(project); unequal.tracks[0].notes.splice(0, 1)
  const incomplete = newEditor(unequal), before = structuredClone(incomplete)
  assert.throws(() => command(incomplete, 'revoice-led 0 10 rootless C3 C5 G7#9 G7#9 G7#9 G7#9'), /constant number/)
  assert.deepEqual(incomplete, before)
})

test('cross-track paired releases refuse the new command without changing either track or history', () => {
  const file = new JZZ.MIDI.SMF(1, 960), on = new JZZ.MIDI.SMF.MTrk(), off = new JZZ.MIDI.SMF.MTrk()
  for (const key of [60,64,67]) {
    on.add(0, JZZ.MIDI.noteOn(0, key, 90)); off.add(960, JZZ.MIDI.noteOff(0, key, 45))
  }
  on.add(1920, JZZ.MIDI.smfEndOfTrack()); off.add(1920, JZZ.MIDI.smfEndOfTrack()); file.push(on); file.push(off)
  const original = importMidiSource(file.toUint8Array()), editor = newEditor(original), before = structuredClone(editor)
  assert.equal(editor.performance.notes.length, 3)
  assert.ok(editor.performance.notes.every(note => note.track === 0 && note.off.startsWith('1:')))
  assert.throws(() => command(editor, 'revoice-led 0 1 close C3 C5 Dm'), /another source track/)
  assert.deepEqual(editor, before); assert.deepEqual(projectMidi(editor.project), file.toUint8Array())
})
