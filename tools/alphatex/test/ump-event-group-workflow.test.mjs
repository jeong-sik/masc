import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { mkdir, readFile, rm } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { capturedMidiFixture } from './helpers/captured-midi-fixture.mjs'
import { newUmpEditor, umpEditorCommand } from '../ump-editor.mjs'
import { umpSourceEvents, materializeUmp } from '../ump-source.mjs'
import { arrangementEditor, arrangementCommand, arrangementImported } from '../arrangement-editor.mjs'
import { readUmpCapture, saveArrangement, loadArrangement, exportUmpCapture } from '../arrangement-files.mjs'
import { prepareCapturedPlayback } from '../capture-playback.mjs'

const command = (editor, line) => umpEditorCommand(editor, line).editor

test('grouped native rhythm survives Worker adoption, both playback plans, original removal, portable reopen and exact reexport', () => capturedMidiFixture(async ({ root, path, files, imported, rows }) => {
  const directory = join(root, 'scratch'); await mkdir(directory)
  const worker = new Worker(new URL('../arrangement-worker.mjs', import.meta.url)); let id = 0
  const options = { sourceRoot: dirname(path), directory }
  const request = async job => {
    const response = once(worker, 'message'); worker.postMessage({ ...job, id: ++id })
    const [message] = await response; assert.equal(message.ok, true, message.error); return message.result
  }
  try {
    const source = await request({ kind: 'prepare-ump', project: imported.project, asset: imported.asset, ...options })
    const original = umpSourceEvents(rows), ids = original.filter(event => event.source === 'A').map(event => event.id)
    let edited = command(newUmpEditor(source.asset, source.packets, { tempo: 137 }), `select-events ${ids.join(' ')}`)
    edited = command(command(edited, 'shift-events-ticks 4000000'), 'stretch-events 3/2')
    const materialized = materializeUmp(rows, edited.asset.ump, source.asset.parts.midi.sha256)
    assert.deepEqual(materialized.filter(packet => packet.source === 'B'), rows.filter(packet => packet.source === 'B'))
    assert.deepEqual(materialized.filter(packet => packet.source === 'A').map(packet => packet.hostTime),
      [3999900n, 3999900n, 3999900n, 3999900n, 3999900n, 11200050n, 11200050n, 11200050n,
        22000050n, 22000050n, 22000050n, 22000050n].map(offset => String(10000000000000000000n + offset)))
    assert.deepEqual(materialized.filter(packet => packet.source === 'A').flatMap(packet => packet.words),
      rows.filter(packet => packet.source === 'A').flatMap(packet => packet.words))
    const variant = await request({ kind: 'import-ump', project: imported.project, asset: imported.asset, ump: edited.asset.ump, ...options })
    let parent = arrangementImported(arrangementEditor(imported.project), variant)
    parent = arrangementCommand(parent, `place ${variant.asset} 0`).editor
    const snapshot = await request({ kind: 'prepare-take', project: parent.project, asset: variant.asset, ...options })
    const playback = await prepareCapturedPlayback(snapshot.directory, { directory, sourceBindings: [{ source: 'A', destination: '10' }, { source: 'B', destination: '11' }] })
    const standalone = JSON.parse(await readFile(playback.path)).ump
    const arranged = await request({ kind: 'prepare-capture', project: parent.project,
      sourceBindings: [{ asset: variant.asset, source: 'A', destination: '10' }, { asset: variant.asset, source: 'B', destination: '11' }], ...options })
    assert.deepEqual(JSON.parse(await readFile(arranged.path)).umpRegions.sources[0].timeline, standalone)
    assert.deepEqual(standalone.packets, materialized)
    const output = join(root, 'export'); await exportUmpCapture(parent.project, variant.asset, output, options)
    assert.deepEqual(await readFile(join(output, 'audio.wav')), files['audio.wav'])
    assert.deepEqual(await readFile(join(output, 'original-midi.ump.jsonl')), Buffer.from(files['midi.ump.jsonl']))
    const copy = join(root, 'portable/song.json'); await saveArrangement(copy, parent.project, null, { sourceRoot: dirname(path) })
    await rm(dirname(path), { recursive: true, force: true })
    const reopened = await loadArrangement(copy)
    const restored = await readUmpCapture(reopened.project, variant.asset, { sourceRoot: dirname(copy), directory })
    const editor = newUmpEditor(restored.asset, restored.packets, { tempo: reopened.project.tempo })
    assert.deepEqual(editor.eventSelection, [])
    assert.deepEqual(materializeUmp(restored.packets, editor.asset.ump, editor.asset.parts.midi.sha256), materialized)
    const reexport = join(root, 'reexport'); await exportUmpCapture(reopened.project, variant.asset, reexport, { sourceRoot: dirname(copy), directory })
    for (const name of ['midi.ump.jsonl', 'session.json', 'audio.wav', 'audio-blocks.jsonl', 'original-midi.ump.jsonl', 'ump-source.json'])
      assert.deepEqual(await readFile(join(output, name)), await readFile(join(reexport, name)))
  } finally { await worker.terminate() }
}))
