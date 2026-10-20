import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { readFile, readdir, mkdir, writeFile, chmod } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { practiceSourceFixture } from './helpers/practice-source-fixture.mjs'
import { nominalMidiFrame } from '../render-midi-clock.mjs'
import { phraseBacking } from '../phrase-backing.mjs'
import { newArrangement } from '../arrangement.mjs'
import { importArrangementPractice, importPracticeMidi, saveArrangement, loadArrangement } from '../arrangement-files.mjs'
import { arrangementEditor, arrangementCommand, arrangementImported, arrangementAction } from '../arrangement-editor.mjs'
import { midiSourcePattern, midiSourceHarmony, exportMidiSource } from '../midi-source.mjs'
import { newEditor, editorCommand, editorAction } from '../sequencer-editor.mjs'
import { importPhraseDocument } from '../phrase-arrangement.mjs'

async function fixture(run, messages = [
  [-1n, [0xb5, 64, 127]],
  ...[60, 64, 67, 71].map(pitch => [120000n, [0x95, pitch, 100]]),
  [240000n, [0xe5, 1, 65]], [240001n, [0xd5, 44]],
  ...[60, 64, 67, 71].map(pitch => [360000n, [0x85, pitch, 47]]),
]) {
  return practiceSourceFixture(async data => {
    const { root, arm, context, rows, receipt, publish, input } = data
    context.project.tempo = 137; context.project.meter = [7, 8]
    context.backing = phraseBacking(context.project, context.track, true)
    arm.renderClock.anchor.hostTime = '18446744000000000000'
    rows.splice(0, rows.length, ...messages.map(([delta, bytes], index) => {
      const words = bytes.length === 2 && bytes[0] > 255 ? bytes : [((0x23 << 24) | (bytes[0] << 16) | (bytes[1] << 8) | (bytes[2] ?? 0)) >>> 0]
      const packet = { kind: 'midi', protocol: 2, source: '10', ordinal: String(index),
        hostTime: String(BigInt(arm.renderClock.anchor.hostTime) + delta), timestampOrigin: 'packet', words }
      return { packet, nominalFrame: nominalMidiFrame(packet.hostTime, arm.input.clock, arm.renderClock) }
    }))
    receipt.packets = String(rows.length)
    receipt.inputFinal.admittedPackets = receipt.inputFinal.acknowledgedPackets = receipt.packets
    await publish()
    const path = join(root, 'project/song.json'), imported = await importArrangementPractice(newArrangement(), input, { projectPath: path })
    const directory = join(root, 'scratch'); await mkdir(directory)
    const worker = new Worker(new URL('../arrangement-worker.mjs', import.meta.url)); let id = 0
    const request = async job => {
      const pending = once(worker, 'message'); worker.postMessage({ ...job, id: ++id })
      const [reply] = await pending; if (!reply.ok) throw new Error(reply.error); return reply.result
    }
    try { await run({ ...data, path, imported, directory, request }) } finally { await worker.terminate() }
  })
}

test('actual Worker derives expressive recorded MIDI for revoice, harmony, independent edits, placement and portable save', () => fixture(async ({ imported, path, directory, request, context, rows, files, root }) => {
  const original = structuredClone(imported.project), parts = await Promise.all(Object.values(files).map(file => readFile(file)))
  let editor = arrangementEditor(imported.project)
  editor = arrangementCommand(editor, `practice-region ${imported.asset} 0 0 1 2`).editor
  const rawClip = structuredClone(editor.project.clips[0])
  const effect = arrangementCommand(editor, 'practice-midi').effect
  assert.deepEqual(effect, { kind: 'practice-midi', asset: imported.asset })
  const result = await request({ ...effect, project: editor.project, sourceRoot: dirname(path), directory })
  editor = arrangementImported(editor, result)
  const asset = editor.project.assets.at(-1), source = asset.source, performance = midiSourcePattern(source)
  assert.deepEqual(source.sound, context.project.sound)
  assert.deepEqual(performance.timing, { kind: 'ppq', ppq: 960 })
  assert.deepEqual(performance.diagnostics, []); assert.equal(performance.notes.length, 4)
  assert.ok(midiSourceHarmony(source, performance.notes[0].seconds + 0.001).candidates.includes('Cmaj7'))
  const wire = performance.events.filter(event => event.kind === 'channel')
  // Independent rational nearest-tick oracle at the SMF tempo, with UInt64 origin.
  const micros = 437956n, origin = BigInt(rows[0].packet.hostTime)
  const tick = host => Number(((BigInt(host) - origin) * 125n * 960n * 2n + 3n * micros * 1000n) / (6n * micros * 1000n))
  assert.deepEqual(wire.slice(2, -3).map(event => [event.tick, event.bytes]), rows.map(row => {
    const word = row.packet.words[0]
    const bytes = [(word >>> 16 & 0xf0) | context.backing.channel, word >>> 8 & 127]
    if (![0xc0, 0xd0].includes(bytes[0] & 0xf0)) bytes.push(word & 127)
    return [tick(row.packet.hostTime), bytes]
  }))
  assert.deepEqual(wire.slice(0, 2).map(event => event.bytes), context.backing.initial)
  assert.deepEqual(wire.slice(-3).map(event => event.bytes), [64, 66, 69].map(cc => [0xb0 | context.backing.channel, cc, 0]))
  let child = editorCommand(newEditor(source), `select ${performance.notes[0].id}`).editor
  child = editorCommand(child, 'revoice Cmaj7 drop2').editor
  assert.deepEqual(midiSourcePattern(child.project).notes.map(note => note.pitch).sort((a,b) => a-b), [55,60,64,71])
  child = editorAction(child, { kind: 'undo' }); assert.deepEqual(child.project, source)
  child = editorAction(child, { kind: 'redo' })
  const variant = importPhraseDocument(editor.project, child.project)
  assert.deepEqual(editor.project.assets.at(-1).source, source)
  editor = arrangementImported(editor, variant)
  editor = arrangementCommand(editor, 'cursor 4').editor; editor = arrangementAction(editor, { kind: 'place' })
  assert.equal(editor.project.clips.at(-1).position, 3840)
  assert.deepEqual(editor.project.clips[0], rawClip)
  assert.equal(editor.project.assets.find(asset => asset.id === imported.asset).kind, 'practice')
  const saved = join(root, 'moved/song.json'); await saveArrangement(saved, editor.project, null, { sourceRoot: dirname(path) })
  const loaded = await loadArrangement(saved); assert.deepEqual(loaded.project, editor.project)
  assert.deepEqual(Buffer.from(exportMidiSource(loaded.project.assets.at(-1).source)), Buffer.from(exportMidiSource(child.project)))
  assert.deepEqual(imported.project, original)
  assert.deepEqual(await Promise.all(Object.values(files).map(file => readFile(file))), parts)
  assert.deepEqual(await readdir(directory), [])
  assert.throws(() => arrangementCommand(editor, 'practice-midi'), /raw practice/)
}))

test('MIDI2 projection keeps supported values, same-tick note order, and explicit end releases', () => fixture(async ({ imported, path, directory, request }) => {
  const result = await request({ kind: 'practice-midi', project: imported.project, asset: imported.asset, sourceRoot: dirname(path), directory })
  const performance = midiSourcePattern(result.project.assets.at(-1).source)
  assert.deepEqual(performance.notes.map(({ pitch, start, duration, velocity }) => ({ pitch, start, duration, velocity })), [
    { pitch: 60, start: 0, duration: 0, velocity: 72 }, { pitch: 60, start: 0, duration: 219, velocity: 64 },
  ])
  assert.deepEqual(performance.diagnostics, [])
  assert.deepEqual(await readdir(directory), [])
}, [[0n, [0x43953c00, 0x90000000]], [1n, [0x43853c00, 0x12000000]], [2n, [0x43953c00, 0x80000000]]]))

test('unsupported attributes fail atomically; corrupt source and cancellation leave no private snapshot', () => fixture(async ({ imported, path, directory, request }) => {
  const before = structuredClone(imported.project), job = { kind: 'practice-midi', project: imported.project, asset: imported.asset, sourceRoot: dirname(path), directory }
  await assert.rejects(request(job), /attributes/)
  const abort = new AbortController(); abort.abort()
  await assert.rejects(importPracticeMidi(imported.project, imported.asset, { sourceRoot: dirname(path), directory, signal: abort.signal }), { name: 'AbortError' })
  const events = join(dirname(path), imported.project.assets[0].parts.events.file)
  await chmod(events, 0o600); await writeFile(events, '{}\n')
  await assert.rejects(request(job))
  assert.deepEqual(imported.project, before); assert.deepEqual(await readdir(directory), [])
}, [[0n, [0x43953c03, 0x90012345]]]))
