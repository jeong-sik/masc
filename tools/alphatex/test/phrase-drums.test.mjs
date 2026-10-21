import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { newEditor, editorCommand, editorAction } from '../sequencer-editor.mjs'
import { harmonyAt, GM_DRUM_CHANNEL, PPQ, sequenceEvents } from '../sequencer-project.mjs'
import { saveProject, loadProject, projectMidi } from '../sequencer-files.mjs'
import { projectMidiTimeline } from '../sequencer-midi.mjs'
import { arrangementFromPhrase, phraseDocument, verifyPhraseSnapshot } from '../phrase-arrangement.mjs'
import { renderProject } from '../sequencer-audio.mjs'
import { readWaveMetadata } from '../wave-file.mjs'
import { phraseBacking } from '../phrase-backing.mjs'
midiFiles(JZZ)

const command = (editor, line) => editorCommand(editor, line).editor
function groove() {
  let editor = newEditor()
  for (const line of ['length 4', 'chord Cmaj7 0 4', 'track-add Bass', 'program 33', 'note C2 0 4 90',
    'drum-track Drums', 'level 80', 'pan 48', 'note 36 0 0.25 110', 'note 38 1 0.25 100',
    'note 42 0 0.25 70', 'note 42 0.5 0.25 60', 'note 38 3 0.25 95']) editor = command(editor, line)
  return editor
}
async function analysis(project, scope) {
  const worker = new Worker(new URL('../sequencer-worker.mjs', import.meta.url))
  try {
    const reply = once(worker, 'message')
    worker.postMessage({ id: 1, project, cancel: new SharedArrayBuffer(4), options: { format: 'harmony', scope } })
    return (await reply)[0]
  } finally { await worker.terminate() }
}

test('compose a drum groove, undo/redo, save, reopen, export and arrangement handoff keep channel 10 and exact hits', async () => {
  let editor = groove()
  const drums = editor.project.tracks[editor.track]
  assert.equal(drums.channel, GM_DRUM_CHANNEL)
  assert.equal(drums.name, 'Drums')
  assert.deepEqual(editor.project.tracks.map(track => track.channel), [0, 1, 9])
  const original = structuredClone(editor.project)
  editor = editorAction(editor, { kind: 'undo' })
  assert.equal(editor.project.tracks[2].notes.length, 4)
  editor = editorAction(editor, { kind: 'redo' })
  assert.deepEqual(editor.project, original)
  assert.throws(() => command(editor, 'drum-track Other kit'), /already has a track/)
  for (const line of ['chord Cmaj7 0 4', 'revoice Cmaj7 drop2', 'progression 0 1 close C Dm']) {
    assert.throws(() => command(editor, line), /melodic track/)
    assert.deepEqual(editor.project, original)
  }
  const directory = await mkdtemp(join(tmpdir(), 'masc-phrase-drums-'))
  try {
    const path = join(directory, 'groove.json')
    await saveProject(path, editor.project)
    const reopened = (await loadProject(path)).project
    assert.deepEqual(reopened, original)
    const file = new JZZ.MIDI.SMF(projectMidi(reopened)), output = [...file[3]]
    assert.deepEqual(output.filter(event => event.isNoteOn()).map(event => [event.tt, event.getChannel(), event.getNote(), event.getVelocity()]),
      [[0,9,36,110],[0,9,42,70],[PPQ/2,9,42,60],[PPQ,9,38,100],[3*PPQ,9,38,95]])
    assert.deepEqual(output.filter(event => event.isNoteOff()).map(event => [event.tt, event.getChannel(), event.getNote()]),
      [[PPQ/4,9,36],[PPQ/4,9,42],[3*PPQ/4,9,42],[5*PPQ/4,9,38],[13*PPQ/4,9,38]])
    const arranged = arrangementFromPhrase(reopened), asset = arranged.project.assets[0]
    verifyPhraseSnapshot(asset)
    assert.deepEqual(phraseDocument(arranged.project, asset.id), reopened)
    assert.deepEqual(Buffer.from(asset.source.original, 'base64'), Buffer.from(projectMidi(reopened)))
  } finally { await rm(directory, { recursive: true, force: true }) }
})

test('pitched harmony ignores authored GM drum hits; explicit drum analysis refuses while source channel semantics stay intact', async () => {
  const { project } = groove(), before = structuredClone(project)
  assert.deepEqual(harmonyAt(project, 0).pitches, [36,60,64,67,71])
  assert.deepEqual(harmonyAt(project, 0, { all: true }).pitches, [36,60,64,67,71])
  const result = await analysis(project, { kind: 'mix' })
  assert.equal(result.ok, true)
  assert.equal(result.result.rows.length, 1)
  assert.deepEqual(result.result.rows[0].pitches, [36,60,64,67,71])
  assert.ok(result.result.rows[0].candidates.includes('Cmaj7'))
  const refused = await analysis(project, { kind: 'track', id: project.tracks[2].id })
  assert.equal(refused.ok, false)
  assert.match(refused.error, /melodic track/)
  const source = arrangementFromPhrase(project).project.assets[0].source
  const imported = await analysis(source, { kind: 'track', id: '3', channel: GM_DRUM_CHANNEL })
  assert.equal(imported.ok, true)
  assert.deepEqual(imported.result.rows[0].pitches, [36,42])
  assert.deepEqual(project, before)
})

test('drum mute/solo, clipped MIDI loop and practice backing all retain the same channel and controls', () => {
  let editor = groove()
  editor = command(editor, 'loop 0.125 2')
  editor = editorAction(editor, { kind: 'solo' })
  const project = editor.project, loop = sequenceEvents(project, { loop: true })
  assert.ok(loop.events.every(event => event.channel === GM_DRUM_CHANNEL))
  assert.deepEqual(loop.events.filter(event => event.kind === 'on').map(event => [event.tick,event.pitch]), [[0,36],[0,42],[360,42],[840,38]])
  const transport = projectMidiTimeline(project, { loop: true })
  assert.ok(transport.events.every(event => event.channel === GM_DRUM_CHANNEL))
  assert.ok(transport.events.some(event => event.kind === 'control' && event.controller === 7 && event.value === 80))
  const backing = phraseBacking(project, project.tracks[0].id, true)
  assert.deepEqual(backing.channels, [GM_DRUM_CHANNEL])
  assert.deepEqual(backing.events.filter(event => event.bytes[0] === 0x99).map(event => event.bytes[1]), [36,42,42,38])
  assert.deepEqual(harmonyAt(project, 0).pitches, [])
  editor = editorAction(editor, { kind: 'mute' })
  assert.deepEqual(sequenceEvents(editor.project).events, [])
})

test('the actual default synth renders the solo drum groove and zero track level makes its PCM silent', async () => {
  let editor = editorAction(groove(), { kind: 'solo' })
  const directory = await mkdtemp(join(tmpdir(), 'masc-phrase-drums-pcm-'))
  try {
    const audible = join(directory, 'drums.wav')
    const receipt = renderProject(editor.project, audible, { loop: true })
    const metadata = await readWaveMetadata(audible)
    assert.ok(receipt.peak > 0)
    assert.equal(metadata.frames, BigInt(Math.round(4 * 60 / editor.project.tempo * 44100)))
    assert.ok((await readFile(audible)).length > metadata.dataOffset)
    editor = command(editor, 'level 0')
    assert.equal(renderProject(editor.project, join(directory, 'silent.wav'), { loop: true }).peak, 0)
  } finally { await rm(directory, { recursive: true, force: true }) }
})
