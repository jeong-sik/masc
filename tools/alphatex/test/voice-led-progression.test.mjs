import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { Chord, Note } from 'tonal'
import { newEditor, editorCommand, editorAction } from '../sequencer-editor.mjs'
import { voiceLedProgression, chordVoicing, PPQ } from '../sequencer-project.mjs'
import { saveProject, loadProject, projectMidi } from '../sequencer-files.mjs'
import { arrangementFromPhrase, phraseDocument, verifyPhraseSnapshot } from '../phrase-arrangement.mjs'
midiFiles(JZZ)

const command = (editor, line) => editorCommand(editor, line).editor
const distance = (a, b) => a.reduce((sum, key, index) => sum + Math.abs(key - b[index]), 0)
const movement = rows => rows.slice(1).reduce((sum, row, index) => sum + distance(rows[index], row), 0)

// Small exhaustive oracle: choose every four-key subset and check its chord
// classes and close/drop2 geometry; no product candidate generator or DP used.
function seventhCandidates(symbol, mode, low, high) {
  const classes = Chord.get(symbol).notes.map(Note.chroma), rows = []
  for (let a = low; a <= high; a++) for (let b = a + 1; b <= high; b++) {
    for (let c = b + 1; c <= high; c++) for (let d = c + 1; d <= high; d++) {
      const row = [a, b, c, d]
      if (new Set(row.map(key => key % 12)).size !== 4 || !row.every(key => classes.includes(key % 12))) continue
      if (mode === 'close' ? d - a < 12 : a + 12 > c && a + 12 < d && d - b < 12) rows.push(row)
    }
  }
  return rows
}
function exhaustive(layers) {
  let best = Infinity
  const visit = (index, path) => {
    if (index === layers.length) { best = Math.min(best, movement(path)); return }
    for (const row of layers[index]) visit(index + 1, [...path, row])
  }
  visit(0, [])
  return best
}

test('actual progression command reaches exhaustive minimum for close and drop2 candidate paths', () => {
  const symbols = ['Dm7', 'G7', 'Cmaj7']
  for (const mode of ['close', 'drop2']) {
    const candidates = symbols.map(symbol => seventhCandidates(symbol, mode, 48, 72))
    let editor = command(newEditor(), `progression-led 0 1 ${mode} C3 C5 ${symbols.join(' ')}`)
    const rows = symbols.map((_, i) => editor.project.tracks[0].notes.filter(note => note.start === i * PPQ).map(note => note.pitch))
    assert.equal(movement(rows), exhaustive(candidates))
    assert.ok(rows.every((row, i) => candidates[i].some(candidate => JSON.stringify(candidate) === JSON.stringify(row))))
    assert.deepEqual(rows, voiceLedProgression(symbols, { mode, low: 48, high: 72 }))
    assert.deepEqual(rows, voiceLedProgression(symbols, { mode, low: 'C3', high: 'C5' }))
  }
})

test('whole rootless progression beats nearest-next-chord choice from every possible starting voicing', () => {
  const symbols = ['G7', 'Em7', 'Cmaj7', 'G7#11']
  // Actual Tonal left-hand dictionary candidates in C3..C5, independently
  // enumerated for this musical counterexample, including both first voicings.
  const candidates = [
    [[53,57,59,64],[59,64,65,69]],
    [[50,54,55,59],[55,59,62,66],[62,66,67,71]],
    [[52,55,59,62],[59,62,64,67]],
    [[53,57,61,65]],
  ]
  const path = voiceLedProgression(symbols, { mode: 'rootless', low: 48, high: 72 })
  const greedyCosts = candidates[0].map(first => {
    const path = [first]
    for (const layer of candidates.slice(1)) path.push(layer.reduce((best, row) => distance(path.at(-1), row) < distance(path.at(-1), best) ? row : best))
    return movement(path)
  })
  assert.equal(exhaustive(candidates), 31)
  assert.equal(movement(path), 31)
  assert.equal(Math.min(...greedyCosts), 35)
  assert.ok(path.every((row, i) => candidates[i].some(candidate => JSON.stringify(candidate) === JSON.stringify(row))))
})

test('slash bass, exact MIDI edges and constant voice count constrain the selected path', () => {
  const slash = voiceLedProgression(['C/E', 'F/A', 'G/B'], { mode: 'close', low: 48, high: 84 })
  assert.deepEqual(slash.map(row => row[0] % 12), [4,9,11])
  assert.deepEqual(voiceLedProgression(['C/F#'], { mode: 'drop2', low: 54, high: 67 }), [[54,60,64,67]])
  assert.deepEqual(voiceLedProgression(['C9'], { mode: 'close', low: 60, high: 70 }), [[60,62,64,67,70]])
  assert.deepEqual(chordVoicing('C9', { mode: 'close', octave: 4 }), [60,64,67,70,74])
  assert.deepEqual(voiceLedProgression(['C'], { mode: 'close', low: 0, high: 7 }), [[0,4,7]])
  assert.deepEqual(voiceLedProgression(['B'], { mode: 'close', low: 119, high: 127 }), [[119,123,126]])
  assert.throws(() => voiceLedProgression(['Cmaj7', 'Dm'], { mode: 'close', low: 48, high: 84 }), /constant number/)
  assert.throws(() => voiceLedProgression(['G7#9', 'Cmaj7'], { mode: 'rootless', low: 48, high: 84 }), /constant number/)
})

test('failed progression commands preserve original notes, dynamics, track controls and undo history', () => {
  let editor = command(newEditor(), 'note C3 0 1 77')
  const original = structuredClone(editor)
  for (const line of [
    'progression-led 0 1 close C3 C5 Cmaj7', // collides with existing C3
    'progression-led 0 1 close C5 C3 Cmaj7',
    'progression-led 0 1 close C4 D4 Cmaj7',
    'progression-led 0 1 drop2 C3 C5 C',
    'progression-led 0 1 rootless C3 C5 Cmaj7/E',
    'progression-led 0 1 close C3 C5 NotAChord',
    'progression-led 0 1 unknown C3 C5 Cmaj7',
    'progression-led 0 0 close C3 C5 Cmaj7',
    'progression-led 15 2 close C3 C5 Cmaj7',
    'progression-led 0 1 close -1 128 Cmaj7',
  ]) {
    assert.throws(() => command(editor, line), line)
    assert.deepEqual(editor, original)
  }
  editor = command(editor, 'drum-track Drums')
  const drums = structuredClone(editor)
  assert.throws(() => command(editor, 'progression-led 0 1 close C3 C5 Cmaj7'), /melodic track/)
  assert.deepEqual(editor, drums)
})

test('undo, save/reopen, actual SMF, harmony worker and editable arrangement retain the chosen progression', async () => {
  let editor = editorAction(command(newEditor(), 'length 4'), { kind: 'velocity', value: 81 })
  const before = structuredClone(editor.project)
  editor = command(editor, 'progression-led 0 1 rootless 48 72 G7 Em7 Cmaj7 G7#11')
  const original = structuredClone(editor.project), notes = original.tracks[0].notes
  assert.equal(notes.length, 16)
  assert.ok(notes.every(note => note.velocity === 81 && note.duration === PPQ))
  assert.equal(editor.undo.length, 2)
  editor = editorAction(editor, { kind: 'undo' }); assert.deepEqual(editor.project, before)
  editor = editorAction(editor, { kind: 'redo' }); assert.deepEqual(editor.project, original)
  const root = await mkdtemp(join(tmpdir(), 'masc-voice-leading-'))
  const worker = new Worker(new URL('../sequencer-worker.mjs', import.meta.url))
  try {
    const path = join(root, 'progression.json')
    await saveProject(path, editor.project)
    const reopened = (await loadProject(path)).project
    assert.deepEqual(reopened, original)
    const smf = new JZZ.MIDI.SMF(projectMidi(reopened)), exported = [...smf[1]]
    assert.deepEqual(exported.filter(event => event.isNoteOn()).map(event => [event.tt, event.getNote(), event.getVelocity()]), notes.map(note => [note.start, note.pitch, 81]))
    assert.deepEqual(exported.filter(event => event.isNoteOff()).map(event => [event.tt, event.getNote()]), notes.map(note => [note.start + note.duration, note.pitch]))
    const reply = once(worker, 'message')
    worker.postMessage({ id: 1, project: reopened, cancel: new SharedArrayBuffer(4), options: { format: 'harmony', scope: { kind: 'mix' } } })
    const result = (await reply)[0]
    assert.equal(result.ok, true)
    assert.deepEqual(result.result.rows.map(row => [row.start, row.end, row.pitches]), [
      [0,PPQ,[53,57,59,64]], [PPQ,2*PPQ,[55,59,62,66]],
      [2*PPQ,3*PPQ,[52,55,59,62]], [3*PPQ,4*PPQ,[53,57,61,65]],
    ])
    const arranged = arrangementFromPhrase(reopened), asset = arranged.project.assets[0]
    verifyPhraseSnapshot(asset)
    assert.deepEqual(phraseDocument(arranged.project, asset.id), reopened)
    assert.deepEqual(Buffer.from(asset.source.original, 'base64'), Buffer.from(projectMidi(reopened)))
    // Source editing keeps its existing explicit contract.
    assert.throws(() => command(newEditor(asset.source), 'progression-led 0 1 close C3 C5 Dm7 G7 Cmaj7'))
  } finally { await worker.terminate(); await rm(root, { recursive: true, force: true }) }
})
