import { StatusReader } from '../status-reader.mjs'
import test from 'node:test'
import assert from 'node:assert/strict'
import { newEditor, editorCommand, editorAction, selectedNote } from '../sequencer-editor.mjs'
import { projectMidi, loadProject, saveProject } from '../sequencer-files.mjs'
import { harmonyAt, PPQ } from '../sequencer-project.mjs'
import { newArrangement } from '../arrangement.mjs'
import { defaultStateDirectory } from '../vst.mjs'
import * as terminalStyle from '../terminal-style.mjs'
import { mkdtemp, rm, readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { randomUUID } from 'node:crypto'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
midiFiles(JZZ)

test('revoicing compares existing voices with undo and retains rhythm, dynamics, other parts and exported keys', async () => {
  let editor = newEditor()
  const command = line => { editor = editorCommand(editor, line).editor }
  command('chord Cmaj7 0 4')
  command('chord Dm7 4 4')
  command('cursor 1 E4')
  editor = editorAction(editor, { kind: 'velocity', value: 83 })
  editor = editorAction(editor, { kind: 'duration', value: 3 * PPQ })
  command('track-add Bass'); command('note C2 0 8 105'); command('track 1')
  const before = structuredClone(editor.project), id = selectedNote(editor).id
  command('revoice Cmaj7 drop2 4 0')
  const changed = editor.project
  assert.deepEqual(changed.tracks[0].notes.slice(0, 4).map(n => n.pitch), [55, 60, 64, 71])
  assert.equal(selectedNote(editor).id, id)
  for (const note of before.tracks[0].notes) {
    const { pitch, ...rest } = note, { pitch: nextPitch, ...after } = changed.tracks[0].notes.find(n => n.id === note.id)
    assert.deepEqual(after, rest)
    if (note.start >= 4 * PPQ) assert.equal(nextPitch, pitch)
  }
  assert.deepEqual(changed.tracks[1], before.tracks[1])
  command('undo'); assert.deepEqual(editor.project, before)
  assert.equal(selectedNote(editor).id, id)
  const dynamics = editorAction(editor, { kind: 'velocity', value: 101 })
  assert.equal(dynamics.project.tracks[0].notes.find(note => note.id === id).velocity, 101)
  assert.equal(dynamics.project.tracks[0].notes.find(note => note.id !== id).velocity, 96)
  command('redo'); assert.deepEqual(editor.project, changed)
  assert.equal(selectedNote(editor).id, id)
  command('revoice Cmaj7 rootless 3'); assert.equal(editor.project.tracks[0].notes.length, 8)
  command('undo'); assert.deepEqual(editor.project, changed)
  const dir = await mkdtemp(join(tmpdir(), 'masc-revoice-'))
  try {
    const path = join(dir, 'voicing.json')
    await saveProject(path, changed)
    const reopened = (await loadProject(path)).project
    assert.deepEqual(reopened, changed)
    const midi = new JZZ.MIDI.SMF(projectMidi(reopened))
    assert.deepEqual([...midi[1]].filter(e => e.isNoteOn() && e.tt === 0).map(e => e.getNote()), [55, 60, 64, 71])
    assert.ok([...midi[1]].some(e => e.isNoteOff() && e.getNote() === 60 && e.tt === 3 * PPQ))
  } finally { await rm(dir, { recursive: true, force: true }) }
})

test('revoicing never partly edits the draft on changed voice count or a new same-key overlap', () => {
  const editor = editorCommand(newEditor(), 'chord Cmaj7 0 4').editor
  const before = structuredClone(editor)
  for (const command of ['revoice C close', 'revoice nope close', 'revoice Cmaj7 drop2 9']) {
    assert.throws(() => editorCommand(editor, command))
    assert.deepEqual(editor, before)
  }
  const collision = editorCommand(editor, 'note G3 3 1').editor
  const collisionBefore = structuredClone(collision)
  assert.throws(() => editorCommand(collision, 'revoice Cmaj7 drop2 4'), /Overlapping/)
  assert.deepEqual(collision, collisionBefore)
  const empty = editorCommand(editor, 'cursor 8 C4').editor
  assert.throws(() => editorCommand(empty, 'revoice Cmaj7 close'), /No notes sounding/)
})

test('musician creates a progression and bass, changes sound, solos, undoes and reopens', async () => {
  let editor = newEditor()
  const command = line => { editor = editorCommand(editor, line).editor }
  command('progression 0 4 rootless Dm7 G7 Cmaj7')
  const harmony = editor.project
  assert.equal(harmony.tracks[0].notes.length, 12)
  command('track-add Electric bass')
  command('program 33')
  command('level 80')
  command('pan 32')
  command('note D2 0 4 110')
  command('note G2 4 4 105')
  command('note C2 8 4 100')
  command('solo')
  assert.equal(editor.project.tracks[1].level, 80)
  assert.equal(editor.project.tracks[1].pan, 32)
  assert.deepEqual(harmonyAt(editor.project, 0).pitches, [38])
  command('undo')
  assert.equal(editor.project.tracks[1].solo, false)
  command('redo')
  assert.equal(editor.project.tracks[1].solo, true)
  const dir = await mkdtemp(join(tmpdir(), 'masc-phrase-workflow-'))
  try {
    const path = join(dir, 'experiment.json')
    await saveProject(path, editor.project)
    assert.deepEqual((await loadProject(path)).project, editor.project)
    assert.ok(projectMidi(editor.project).length > 0)
  } finally { await rm(dir, { recursive: true, force: true }) }
})
test('piano-roll decisions insert, move, resize, change velocity and remove the selected note', () => {
  let editor = newEditor()
  const action = value => { editor = editorAction(editor, value) }
  action({ kind: 'toggle-note' })
  action({ kind: 'move-note', ticks: PPQ / 4, pitches: 2 })
  assert.deepEqual([editor.tick, editor.pitch, selectedNote(editor).start], [PPQ / 4, 62, PPQ / 4])
  action({ kind: 'duration', value: 2 * PPQ })
  action({ kind: 'velocity', value: 120 })
  assert.equal(selectedNote(editor).duration, 2 * PPQ)
  assert.equal(selectedNote(editor).velocity, 120)
  action({ kind: 'toggle-note' })
  assert.equal(editor.project.tracks[0].notes.length, 0)
  action({ kind: 'undo' })
  assert.equal(editor.project.tracks[0].notes.length, 1)
  action({ kind: 'move', ticks: -100000, pitches: -200 })
  assert.deepEqual([editor.tick, editor.pitch], [0, 0])
})
test('invalid commands are transactional and IO is returned as explicit effects', () => {
  const editor = newEditor()
  assert.throws(() => editorCommand(editor, 'note C4 -1 1'), /beat position/)
  assert.throws(() => editorCommand(editor, 'tempo 0'), /tempo/)
  assert.throws(() => editorCommand(editor, 'chord nope 0 4'), /Unknown chord/)
  assert.throws(() => editorCommand(editor, 'note C4 0'), /arguments/)
  assert.throws(() => editorCommand(editor, 'track 2'), /track/)
  assert.equal(editor.project.tracks[0].notes.length, 0)
  assert.deepEqual(editorCommand(editor, 'save-as /tmp/My phrase.json').effect, { kind: 'save-as', path: '/tmp/My phrase.json' })
  assert.deepEqual(editorCommand(editor, 'export /tmp/phrase.mid').effect, { kind: 'export', path: '/tmp/phrase.mid' })
})

test('editor admission rejects arrangements, unknown kinds and malformed phrase documents', () => {
  assert.throws(() => newEditor(newArrangement()), /Unsupported sequencer editor document/)
  assert.throws(() => newEditor({ ...newEditor().project, kind: 'unknown' }), /Unsupported sequencer editor document/)
  assert.throws(() => newEditor(null), /Unsupported sequencer document/)
  assert.throws(() => newEditor({ ...newEditor().project, tracks: undefined }), /needs a track/)
})

test('loading a saved arrangement dispatches before phrase terminal or background resource admission', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'masc-arrangement-editor-admission-'))
  const slot = `sequencer-admission-${randomUUID()}`
  const ownership = { raw: [], workers: 0, temporary: 0 }
  const dispatched = []
  const process = { stdin: { isTTY: true, setRawMode(value) { ownership.raw.push(value) } }, stdout: { isTTY: true } }
  globalThis[slot] = { StatusReader, ...terminalStyle, process, loadProject, newEditor, join, tmpdir, randomUUID, defaultStateDirectory,
    async openArrangement(options) { dispatched.push(options) },
    async mkdtemp() { ownership.temporary++; throw new Error('Unexpected terminal temporary directory') },
    Worker: class { constructor() { ownership.workers++; throw new Error('Unexpected terminal worker') } } }
  try {
    const path = join(directory, 'arrangement.json')
    await saveProject(path, newArrangement())
    assert.equal((await loadProject(path)).project.kind, 'arrangement')
    const source = (await readFile(new URL('../sequencer-tui.mjs', import.meta.url), 'utf8')).replace(/^import .*$/gm, '')
      .replace("await import('./arrangement-tui.mjs')", 'await Promise.resolve({ viewArrangement: openArrangement })')
    const prefix = `const {${Object.keys(globalThis[slot]).join(',')}} = globalThis[${JSON.stringify(slot)}];\n`
    const { viewSequencer } = await import('data:text/javascript;base64,' + Buffer.from(prefix + source).toString('base64'))
    await viewSequencer({ path, root: directory })
    assert.equal(dispatched.length, 1)
    assert.equal(dispatched[0].loaded.path, path)
    assert.deepEqual(dispatched[0].loaded.project, newArrangement())
    assert.equal(dispatched[0].stateDirectory, defaultStateDirectory())
    const stateDirectory = join(directory, 'chosen-vst-state')
    await viewSequencer({ path, root: directory, stateDirectory })
    assert.equal(dispatched.length, 2)
    assert.equal(dispatched[1].loaded.path, path)
    assert.deepEqual(dispatched[1].loaded.project, newArrangement())
    assert.equal(dispatched[1].stateDirectory, stateDirectory)
    assert.deepEqual(ownership, { raw: [], workers: 0, temporary: 0 })
  } finally { delete globalThis[slot]; await rm(directory, { recursive: true, force: true }) }
})
