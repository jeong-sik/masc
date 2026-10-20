import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile, writeFile, chmod, readdir, mkdir, rm } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { once } from 'node:events'
import { Worker } from 'node:worker_threads'
import { practiceSourceFixture } from './helpers/practice-source-fixture.mjs'
import { newArrangement } from '../arrangement.mjs'
import { arrangementEditor, arrangementCommand, arrangementImported, arrangementAction } from '../arrangement-editor.mjs'
import { importArrangementPractice, restorePracticeBacking, saveArrangement, loadArrangement } from '../arrangement-files.mjs'
import { phraseBacking } from '../phrase-backing.mjs'
import { phraseDocument, verifyPhraseSnapshot } from '../phrase-arrangement.mjs'
import { sequenceEvents, editProject } from '../sequencer-project.mjs'

async function fixture(run, selectedSolo = false) {
  await practiceSourceFixture(async data => {
    const { context, publish, root, input } = data, selected = context.project.tracks[0]
    selected.solo = selectedSolo
    selected.notes = [{ id: 'live', pitch: 72, start: 0, duration: 960, velocity: 80 }]
    context.project.tempo = 123; context.project.meter = [7, 8]; context.project.loop = { start: 960, end: 4800 }
    context.project.tracks.push(...[1, 2, 3].map(channel => ({ ...selected, id: `back-${channel}`, name: `Backing ${channel}`, channel,
      solo: channel === 2 && !selectedSolo, muted: channel === 3, level: 20 + channel, pan: 30 + channel,
      notes: [{ id: 'n', pitch: 48 + channel, start: 480, duration: 1920, velocity: 65 }] })))
    context.backing = phraseBacking(context.project, context.track, true); await publish()
    const path = join(root, 'project/song.json'), imported = await importArrangementPractice(newArrangement(), input, { projectPath: path })
    const scratch = join(root, 'scratch'); await mkdir(scratch)
    await run({ ...data, path, imported, scratch })
  })
}
async function workerRequests(run) {
  const worker = new Worker(new URL('../arrangement-worker.mjs', import.meta.url)); let id = 0
  const request = async job => {
    const pending = once(worker, 'message'); worker.postMessage({ ...job, id: ++id })
    const [message] = await pending
    if (!message.ok) throw new Error(message.error)
    return message.result
  }
  try { await run(request) } finally { await worker.terminate() }
}

for (const selectedSolo of [false, true]) test(`worker restores verified frozen backing and retains audibility decisions (live solo ${selectedSolo})`, () => fixture(async ({ context, imported, path, scratch }) => {
  const before = structuredClone(imported.project), source = before.assets[0], originals = await Promise.all(Object.values(source.parts).map(part => readFile(join(dirname(path), part.file))))
  await workerRequests(async request => {
    const initial = arrangementEditor(imported.project), effect = arrangementCommand(initial, 'practice-backing').effect
    assert.deepEqual(effect, { kind: 'practice-backing', asset: source.id })
    assert.deepEqual(arrangementCommand(initial, `practice-backing ${source.id}`).effect, effect)
    const result = await request({ ...effect, project: initial.project, sourceRoot: dirname(path), directory: scratch })
    let editor = arrangementImported(initial, result)
    const asset = editor.project.assets.at(-1), phrase = phraseDocument(editor.project, asset.id), expected = structuredClone(context.project)
    expected.title += ' backing'; expected.tracks[0].muted = true
    assert.deepEqual(phrase, expected); verifyPhraseSnapshot(asset)
    assert.deepEqual(sequenceEvents(phrase, { loop: true }).events.filter(event => event.kind !== 'program').map(({ tick, channel, kind, pitch, velocity, controller, value }) => ({ tick, channel, kind, pitch, velocity, controller, value })),
      sequenceEvents(context.project, { loop: true }).events.filter(event => event.track !== context.track && event.kind !== 'program').map(({ tick, channel, kind, pitch, velocity, controller, value }) => ({ tick, channel, kind, pitch, velocity, controller, value })))
    assert.deepEqual(editor.project.assets[0], source); assert.deepEqual(imported.project, before); assert.deepEqual(await readdir(scratch), [])
    editor = arrangementAction(editor, { kind: 'undo' }); assert.deepEqual(editor.project, before)
    editor = arrangementAction(editor, { kind: 'redo' }); editor = arrangementCommand(editor, `place ${asset.id} 8`).editor
    assert.equal(editor.project.clips[0].position, 8 * editor.project.ppq)
    const target = join(dirname(path), 'moved/song.json')
    await saveArrangement(target, editor.project, null, { sourceRoot: dirname(path) })
    await rm(dirname(path) + '/assets', { recursive: true })
    const loaded = await loadArrangement(target); assert.deepEqual(loaded.project, editor.project)
    assert.deepEqual(await Promise.all(Object.values(source.parts).map(part => readFile(join(dirname(target), part.file)))), originals)
    const edited = editProject(phrase, 'back-2', { kind: 'track-settings', level: 42 })
    const variant = await request({ kind: 'import-phrase', project: loaded.project, document: edited })
    assert.equal(phraseDocument(variant.project, variant.asset).tracks.find(track => track.id === 'back-2').level, 42)
    assert.deepEqual(phraseDocument(variant.project, asset.id), expected)
    assert.throws(() => arrangementCommand(arrangementEditor(variant.project), `practice-backing ${asset.id}`))
  })
}, selectedSolo))

test('restoration refuses corrupt private parts and cancellation without returning a variant or leaking a snapshot', () => fixture(async ({ imported, path, scratch }) => {
  const project = imported.project, asset = project.assets[0], before = structuredClone(project), controller = new AbortController()
  controller.abort()
  await assert.rejects(restorePracticeBacking(project, asset.id, { sourceRoot: dirname(path), directory: scratch, signal: controller.signal }), { name: 'AbortError' })
  const context = join(dirname(path), asset.parts.context.file); await chmod(context, 0o600); await writeFile(context, '{}')
  await workerRequests(async request => assert.rejects(request({ kind: 'practice-backing', project, asset: asset.id, sourceRoot: dirname(path), directory: scratch })))
  assert.deepEqual(await readdir(scratch), []); assert.deepEqual(project, before)
}))
