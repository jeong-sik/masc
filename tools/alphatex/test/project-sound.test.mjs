import test from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtemp, writeFile, readFile, rm, access } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { validateSound } from '../project-sound.mjs'
import { captureVstSound, renderBoundVst } from '../project-sound-files.mjs'
import { newEditor, editorSound, editorCommand, editorAction } from '../sequencer-editor.mjs'
import { saveProject, loadProject, projectMidi } from '../sequencer-files.mjs'
import { exportMidiSource, importMidiSource } from '../midi-source.mjs'
import { arrangementFromPhrase, phraseDocument, verifyPhraseSnapshot, importPhraseDocument } from '../phrase-arrangement.mjs'
import { saveArrangement, loadArrangement } from '../arrangement-files.mjs'

const bytes = Buffer.from('actual captured native state')
const preset = { data: bytes.toString('base64'), sha256: createHash('sha256').update(bytes).digest('hex') }
const selection = { plugin_path: '/synth.vst3', plugin_name: 'Bass', preset_path: '/external.vstpreset', name: 'Bass' }
const sound = { kind: 'vst', selection, preset, instrument: { identifier: 'BassID', version: '1.2' } }
const temporary = async action => {
  const root = await mkdtemp(join(tmpdir(), 'masc-project-sound-'))
  try { await action(root) } finally { await rm(root, { recursive: true, force: true }) }
}

test('saved phrase/source/portable backing and variants own sound without changing MIDI or notation', async () => temporary(async root => {
  let editor = editorCommand(newEditor(), 'chord Dm7 0 1 drop2 4 0').editor
  const midi = Buffer.from(projectMidi(editor.project))
  editor = editorSound(editor, sound)
  assert.deepEqual(Buffer.from(projectMidi(editor.project)), midi)
  const path = join(root, 'phrase.json')
  await saveProject(path, editor.project)
  const reopened = (await loadProject(path)).project
  assert.deepEqual(reopened.sound, sound)
  let sourceEditor = newEditor(importMidiSource(midi, { notation: { kind: 'alphatex', source: '. :4 D4', tracks: [0] } }))
  const original = structuredClone(sourceEditor.project)
  sourceEditor = editorSound(sourceEditor, sound)
  assert.deepEqual(exportMidiSource(sourceEditor.project), exportMidiSource(original))
  assert.deepEqual(sourceEditor.project.notation, original.notation)
  assert.deepEqual(editorAction(sourceEditor, { kind: 'undo' }).project, original)
  assert.deepEqual(editorAction(editorAction(sourceEditor, { kind: 'undo' }), { kind: 'redo' }).project.sound, sound)
  const sourcePath = join(root, 'source.json'); await saveProject(sourcePath, sourceEditor.project)
  assert.deepEqual((await loadProject(sourcePath)).project, sourceEditor.project)
  const arranged = arrangementFromPhrase(reopened)
  assert.equal(arranged.project.assets[0].kind, 'midi')
  assert.deepEqual(arranged.project.assets[0].source.sound, sound)
  const variant = importPhraseDocument(arranged.project, editorSound(newEditor(phraseDocument(arranged.project, arranged.asset)), { kind: 'soundfont' }).project)
  assert.deepEqual(variant.project.assets[0].source.sound, sound)
  assert.deepEqual(variant.project.assets[1].source.sound, { kind: 'soundfont' })
  const song = join(root, 'portable', 'song.json')
  await saveArrangement(song, variant.project, null, { sourceRoot: root })
  await rm(path); await rm(sourcePath)
  const portable = (await loadArrangement(song)).project
  assert.deepEqual(portable, variant.project)
  assert.deepEqual(phraseDocument(portable, arranged.asset).sound, sound)
  const reordered = structuredClone(portable.assets[0]); reordered.source.sound = { instrument: sound.instrument, preset, selection, kind: 'vst' }
  verifyPhraseSnapshot(reordered)
  reordered.source.sound = { kind: 'soundfont' }
  assert.throws(() => verifyPhraseSnapshot(reordered), /sound disagree/)
  const corrupt = structuredClone(reopened); corrupt.sound.preset.data = Buffer.from('changed').toString('base64')
  await assert.rejects(saveProject(join(root, 'bad.json'), corrupt), /preset content changed/)
  const foreign = structuredClone(reopened); foreign.sound.selection.midi_path = '/different.mid'; foreign.sound.selection.output_path = '/foreign.wav'
  const foreignPath = join(root, 'foreign.json')
  await writeFile(foreignPath, JSON.stringify(foreign))
  await assert.rejects(loadProject(foreignPath), /selection fields/)
  await assert.rejects(saveProject(join(root, 'bad-selection.json'), foreign), /selection fields/)
}))

test('choosing default state captures bytes and identity through an owned native job', async () => {
  let stopped = 0
  const chosen = { ...selection, preset_path: null }, requests = []
  const job = captureVstSound(chosen, { run(request) {
    requests.push(request); return { promise: Promise.resolve({ preset, instrument: sound.instrument }), cancel() { stopped++ } }
  } })
  assert.deepEqual((await job.promise), { ...sound, selection: chosen })
  assert.deepEqual(requests, [{ operation: 'snapshot', ...chosen }]); job.cancel(); assert.equal(stopped, 1)
})

test('playback uses frozen private preset after external file changes, then removes it after child closes', async () => temporary(async root => {
  const external = join(root, 'external.vstpreset'), output = join(root, 'wave.wav')
  await writeFile(external, 'changed or replaced original')
  const chosen = { ...sound, selection: { ...selection, preset_path: external } }
  let complete, entered, cancels = 0
  const started = new Promise(resolve => { entered = resolve })
  const job = renderBoundVst(chosen, { output_path: output, midi_path: '/phrase.mid' }, { run(request) {
    assert.deepEqual(request.expected_instrument, sound.instrument)
    assert.equal(request.preset_path, output + '.vstpreset')
    entered(request)
    return { promise: new Promise(resolve => { complete = resolve }), cancel() { cancels++ } }
  } })
  const request = await started
  assert.deepEqual(await readFile(request.preset_path), bytes)
  await rm(external)
  job.cancel(); let closed = false; job.promise.finally(() => { closed = true }).catch(() => {})
  await new Promise(resolve => setImmediate(resolve)); assert.equal(closed, false)
  assert.deepEqual(await readFile(request.preset_path), bytes); assert.equal(cancels, 1)
  complete({ preset_sha256: preset.sha256 })
  await assert.rejects(job.promise, { code: 'ABORT_ERR' })
  await assert.rejects(access(request.preset_path), { code: 'ENOENT' })
  let calls = 0
  const mismatch = renderBoundVst(chosen, { output_path: output }, { run() {
    calls++; return { promise: Promise.resolve({ preset_sha256: '0'.repeat(64) }), cancel() {} }
  } })
  await assert.rejects(mismatch.promise, /does not match/); assert.equal(calls, 1)
  await assert.rejects(access(output + '.vstpreset'), { code: 'ENOENT' })
  validateSound(chosen)
}))
