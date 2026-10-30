import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { mkdir, readFile, readdir, rm, stat } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { createHash } from 'node:crypto'
import { capturedMidiFixture } from './helpers/captured-midi-fixture.mjs'
import { newUmpEditor, umpEditorCommand } from '../ump-editor.mjs'
import { umpSourceNotes } from '../ump-source.mjs'
import { arrangementEditor, arrangementCommand, arrangementImported, arrangementAction } from '../arrangement-editor.mjs'
import { readUmpCapture, importUmpVariant, exportUmpCapture, saveArrangement, loadArrangement } from '../arrangement-files.mjs'
import { prepareCapturedPlayback } from '../capture-playback.mjs'

test('actual Worker native UMP edit/revoice → variant → both playback plans → export/save/reopen preserve exact originals and 16/32-bit data', () => capturedMidiFixture(async ({ imported, path, rows, root }) => {
  const directory = join(root, 'scratch'); await mkdir(directory)
  const worker = new Worker(new URL('../arrangement-worker.mjs', import.meta.url)); let id = 0
  const request = async job => {
    const response = once(worker, 'message'); worker.postMessage({ ...job, id: ++id })
    const [message] = await response; assert.equal(message.ok, true, message.error); return message.result
  }
  const options = { sourceRoot: dirname(path), directory }
  try {
    const original = structuredClone(imported.project)
    let parent = arrangementEditor(imported.project)
    const effect = arrangementCommand(parent, `edit-ump ${imported.asset}`).effect
    const source = await request({ kind: 'prepare-ump', project: parent.project, asset: effect.asset, ...options })
    assert.deepEqual(source.packets, rows)
    let editor = newUmpEditor(source.asset, source.packets)
    editor = umpEditorCommand(editor, 'revoice Cmaj7 drop2').editor
    editor = umpEditorCommand(editor, 'velocity 0').editor
    const result = await request({ kind: 'import-ump', project: parent.project, asset: effect.asset, ump: editor.asset.ump, ...options })
    parent = arrangementImported(parent, result)
    assert.deepEqual(parent.project.assets[0], original.assets[0]); assert.deepEqual(parent.project.clips, original.clips)
    const variant = parent.project.assets.at(-1)
    assert.deepEqual(variant.parts, original.assets[0].parts)
    parent = arrangementCommand(parent, `place ${variant.id} 0`).editor
    const plan = await request({ kind: 'prepare-capture', project: parent.project, sourceBindings: [
      { asset: variant.id, source: 'A', destination: '10' }, { asset: variant.id, source: 'B', destination: '11' }], ...options })
    const arrangement = JSON.parse(await readFile(plan.path)), packets = arrangement.umpRegions.sources[0].timeline.packets
    const projected = umpSourceNotes(packets, undefined, variant.parts.midi.sha256)
    assert.deepEqual(projected.map(note => note.pitch / 512), [55, 60, 64, 71]); assert.equal(projected[0].velocity, 0)
    assert.deepEqual(projected.map(note => note.index), [60, 64, 67, 71])
    assert.deepEqual(packets.slice(1), rows.slice(1))
    const prepared = await request({ kind: 'prepare-take', project: parent.project, asset: variant.id, ...options })
    const standalone = await prepareCapturedPlayback(prepared.directory, { directory, sourceBindings: [
      { source: 'A', destination: '10' }, { source: 'B', destination: '11' }] })
    assert.deepEqual(JSON.parse(await readFile(standalone.path)).ump.packets, packets)
    const output = join(root, 'native-export')
    const exported = await request({ kind: 'export-ump', project: parent.project, asset: variant.id, path: output, ...options })
    const editedBytes = await readFile(join(output, 'midi.ump.jsonl'))
    assert.equal(createHash('sha256').update(editedBytes).digest('hex'), exported.derivedMidiSha256)
    assert.deepEqual(editedBytes.toString().trimEnd().split('\n').map(JSON.parse), packets)
    assert.deepEqual(await readFile(join(output, 'original-midi.ump.jsonl')), await readFile(join(dirname(path), variant.parts.midi.file)))
    assert.notDeepEqual(
      (({ dev, ino }) => [dev, ino])(await stat(join(output, 'original-midi.ump.jsonl'))),
      (({ dev, ino }) => [dev, ino])(await stat(join(dirname(path), variant.parts.midi.file))))
    const provenance = JSON.parse(await readFile(join(output, 'ump-source.json')))
    assert.deepEqual(provenance.ump, variant.ump); assert.deepEqual(provenance.clock, variant.manifest.clock)
    const copy = join(root, 'portable/song.json')
    await saveArrangement(copy, parent.project, null, { sourceRoot: dirname(path) })
    await rm(dirname(path), { recursive: true, force: true })
    const reopened = await loadArrangement(copy)
    assert.deepEqual(reopened.project, parent.project)
    assert.deepEqual((await readUmpCapture(reopened.project, variant.id, { sourceRoot: dirname(copy), directory })).packets, rows)
    const reset = await importUmpVariant(reopened.project, variant.id, undefined, { sourceRoot: dirname(copy), directory })
    assert.equal(Object.hasOwn(reset.project.assets.at(-1), 'ump'), false)
    assert.deepEqual(JSON.parse(JSON.stringify(reset.project)), reset.project)
    assert.deepEqual(arrangementAction(parent, { kind: 'undo' }).project.assets.at(-1).ump, variant.ump)
    assert.deepEqual(arrangementAction(arrangementImported(arrangementEditor(original), result), { kind: 'undo' }).project, original)
  } finally { await worker.terminate() }
}))

test('invalid/stale UMP edits, cancellation and existing export targets cannot adopt a partial variant or replace original data', () => capturedMidiFixture(async ({ imported, path, root }) => {
  const directory = join(root, 'scratch'); await mkdir(directory)
  const options = { sourceRoot: dirname(path), directory }, project = structuredClone(imported.project), asset = project.assets[0]
  await assert.rejects(importUmpVariant(project, asset.id, { schemaVersion: 1, midiSha256: 'b'.repeat(64), notes: [] }, options), /source/)
  await assert.rejects(importUmpVariant(project, asset.id, { schemaVersion: 1, midiSha256: asset.parts.midi.sha256, notes: [{ packet: 0, word: 1, pitch: 1 }] }, options), /NoteOn/)
  const target = join(root, 'existing'); await mkdir(target)
  await assert.rejects(exportUmpCapture(project, asset.id, target, options), /EEXIST/)
  assert.deepEqual(await readdir(target), [])
  const controller = new AbortController(); controller.abort()
  await assert.rejects(readUmpCapture(project, asset.id, { ...options, signal: controller.signal }), { name: 'AbortError' })
  assert.deepEqual(project, imported.project); assert.deepEqual(await readdir(directory), [])
}))
