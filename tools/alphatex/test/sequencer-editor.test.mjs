import test from 'node:test'
import assert from 'node:assert/strict'
import { newEditor, editorCommand, editorAction, selectedNote } from '../sequencer-editor.mjs'
import { projectMidi, loadProject, saveProject } from '../sequencer-files.mjs'
import { harmonyAt, PPQ } from '../sequencer-project.mjs'
import { mkdtemp, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'

test('musician creates a progression and bass, changes sound, solos, undoes and reopens', async () => {
  let editor = newEditor()
  const command = line => { editor = editorCommand(editor, line).editor }
  command('progression 0 4 rootless Dm7 G7 Cmaj7')
  const harmony = editor.project
  assert.equal(harmony.tracks[0].notes.length, 12)
  command('track-add Electric bass')
  command('program 33')
  command('note D2 0 4 110')
  command('note G2 4 4 105')
  command('note C2 8 4 100')
  command('solo')
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
