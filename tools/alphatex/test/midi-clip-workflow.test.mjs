import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { importMidiDocument } from '../midi-import.mjs'
import { midiClipEditor, midiClipCommand, midiClipRows } from '../midi-clip-editor.mjs'
import { midiClipPerformance, midiClipNotes, midiClipClock } from '../midi-clip-source.mjs'
import { exportMidiClip } from '../midi-clip-files.mjs'
import { saveProject, loadProject, projectMidi } from '../sequencer-files.mjs'
import { readMusicInfo } from '../music-library-info.mjs'
midiFiles(JZZ)

const fixture = () => {
  const clip = new JZZ.MIDI.Clip(); clip.ppqn = 1001
  clip.header.add(0, JZZ.UMP.umpTempo(0, 50000000))
  for (const key of [60, 64, 67, 71]) clip.add(0, JZZ.UMP.umpNoteOn(3, 4, key, key === 60 ? 0 : 65535))
  clip.add(0, JZZ.UMP.umpPnRPN(3, 4, 60, 9, 0xffffffff))
  clip.add(1001, JZZ.UMP.umpNoteOff(3, 4, 60, 65535))
  clip.add(2002, JZZ.UMP.umpNoteOff(3, 4, 64, 65535))
  return Buffer.from(clip.toUint8Array())
}
const run = (editor, line) => midiClipCommand(editor, line).editor
const eventContent = doc => midiClipPerformance(doc).sequence.filter(row => row.words[0] !== 0).map(({ tick, words }) => ({ tick, words }))

test('native Clip edit, revoice, grouped timing, Undo, save/reread and .midi2 export retain one original source', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'masc-clip-workflow-'))
  try {
    const bytes = fixture(), original = importMidiDocument(bytes, { name: 'Native chord' })
    let editor = midiClipEditor(original)
    const index = midiClipNotes(original).map(row => row.index), id = editor.selected
    editor = run(editor, 'revoice Cmaj7 drop2 4 0')
    assert.deepEqual(editor.notes.map(row => row.pitch / 512), [55, 60, 64, 71])
    assert.deepEqual(editor.notes.map(row => row.index), index)
    assert.equal(editor.undo.length, 1); assert.equal(editor.selected, id)
    editor = run(editor, 'undo'); assert.deepEqual(editor.project, original)
    editor = run(editor, 'redo'); editor = run(editor, 'velocity 65534')
    assert.equal(editor.notes[0].velocity, 65534)
    const controller = editor.expressions[0], release = editor.events.find(row => (row.words[0] >>> 20 & 15) === 8)
    editor = run(editor, `select ${controller.id}`); editor = run(editor, 'value32 4294967294')
    assert.equal(editor.expressions[0].words[1], 4294967294)
    editor = run(editor, `select-events ${id} ${controller.id} ${release.id}`)
    const beforeTime = editor.project
    editor = run(editor, 'shift-events-ticks 1001')
    assert.equal(editor.events.find(row => row.id === release.id).tick, '2002')
    assert.equal(editor.events.find(row => row.id === id).tick, '1001')
    editor = run(editor, 'stretch-events 2')
    assert.equal(editor.events.find(row => row.id === release.id).tick, '3003')
    editor = run(editor, 'undo'); editor = run(editor, 'undo'); assert.deepEqual(editor.project, beforeTime)
    editor = run(editor, 'redo'); editor = run(editor, 'redo')
    const path = join(directory, 'clip.json'), output = join(directory, 'clip.midi2')
    const revision = await saveProject(path, editor.project)
    const loaded = await loadProject(path)
    assert.equal(loaded.revision, revision); assert.deepEqual(loaded.project, editor.project)
    const reopened = midiClipEditor(loaded.project)
    assert.deepEqual(reopened.project.original, original.original)
    await exportMidiClip(output, reopened.project)
    const reimported = importMidiDocument(await readFile(output))
    assert.equal(reimported.kind, 'midi-clip')
    assert.deepEqual(eventContent(reimported), eventContent(reopened.project))
    assert.deepEqual(midiClipClock(reimported).sequence.duration, midiClipClock(reopened.project).sequence.duration)
    const info = await readMusicInfo({ kind: 'project', path })
    assert.equal(info.kind, 'midi-clip'); assert.equal(info.ppq, 1001); assert.equal(info.notes, 4)
    assert.equal(info.originalSha256, original.original.sha256)
    assert.throws(() => projectMidi(reopened.project), /native MIDI2/)
    assert.deepEqual(Buffer.from(reopened.project.original.base64, 'base64'), bytes)
  } finally { await rm(directory, { recursive: true, force: true }) }
})

test('failed native edits preserve the complete revision; raw configuration and profile setup remain distinct', () => {
  const project = importMidiDocument(fixture()), editor = midiClipEditor(project), before = JSON.stringify(editor)
  for (const command of ['velocity 65536', 'time -1', 'pitch-absolute 60.001', 'select unknown',
    'value32 4294967296', `select-events ${editor.selected} ${editor.selected}`, 'shift-events-ticks 1']) {
    assert.throws(() => midiClipCommand(editor, command)); assert.equal(JSON.stringify(editor), before)
  }
  const empty = new JZZ.MIDI.Clip()
  let view = midiClipEditor(importMidiDocument(empty.toUint8Array()))
  view = run(view, 'notes'); assert.deepEqual(midiClipRows(view), [])
  assert.throws(() => run(view, 'time 0'), /Select a source/)
})

test('file publication refuses existing paths and cancellation without leaving partial exports', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'masc-clip-export-'))
  try {
    const path = join(directory, 'source.mid'), document = importMidiDocument(fixture())
    await exportMidiClip(path, document)
    const before = await readFile(path)
    await assert.rejects(exportMidiClip(path, document), { code: 'EEXIST' })
    const aborted = new AbortController(); aborted.abort()
    await assert.rejects(exportMidiClip(join(directory, 'cancelled.midi2'), document, { signal: aborted.signal }))
    assert.deepEqual(await readFile(path), before)
    assert.deepEqual(await readdir(directory), ['source.mid'])
    const smf = new JZZ.MIDI.SMF(1, 960); smf.push(new JZZ.MIDI.SMF.MTrk())
    assert.equal(importMidiDocument(smf.toUint8Array()).kind, 'midi-source')
  } finally { await rm(directory, { recursive: true, force: true }) }
})
