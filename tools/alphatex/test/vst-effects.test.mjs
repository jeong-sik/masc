import test from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtemp, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { validateSound, soundIdentity, soundIdentityMatches, effectIdentity } from '../project-sound.mjs'
import { captureVstEffect, renderBoundVst } from '../project-sound-files.mjs'
import { newEditor, editorSound, editorEffect, editorAction, editorCommand } from '../sequencer-editor.mjs'
import { saveProject, loadProject, projectMidi } from '../sequencer-files.mjs'
import { importMidiSource } from '../midi-source.mjs'
import { arrangementFromPhrase, arrangementFromMidiSource } from '../phrase-arrangement.mjs'
import { openVstStream } from '../vst-stream.mjs'

const preset = data => ({ data: Buffer.from(data).toString('base64'), sha256: createHash('sha256').update(data).digest('hex') })
const selection = name => ({ plugin_path: `/${name}.vst3`, plugin_name: null, preset_path: '/mutable-label-only', name })
const effect = name => ({ kind: 'vst-effect', selection: selection(name), preset: preset(name), plugin: { identifier: name, version: '1' } })
const dry = () => ({ kind: 'vst', selection: selection('synth'), preset: preset('synth'), instrument: { identifier: 'synth', version: '1' } })
const wet = () => ({ ...dry(), effects: [effect('distortion'), effect('delay')] })

test('chain order, empty chain and captured bytes are part of sound authority', () => {
  const sound = wet(), identity = soundIdentity(sound)
  assert.equal(soundIdentityMatches(sound, identity), true)
  assert.equal(soundIdentityMatches(sound, { ...identity, effects: identity.effects.toReversed() }), false)
  assert.equal(soundIdentityMatches(dry(), identity), false)
  assert.equal(soundIdentityMatches(sound, soundIdentity(dry())), false)
  assert.equal(soundIdentityMatches(dry(), { ...soundIdentity(dry()), effects: null }), false)
  assert.equal(soundIdentityMatches(dry(), { ...soundIdentity(dry()), effects: [] }), true)
  const corrupt = wet(); corrupt.effects[1].preset.data = Buffer.from('changed').toString('base64')
  assert.throws(() => validateSound(corrupt), /preset content changed/)
  assert.throws(() => validateSound({ kind: 'soundfont', effects: sound.effects }))
  assert.throws(() => validateSound({ ...dry(), effects: null }))
})

test('effect add, reorder, remove and clear survive undo/save/backing without changing notes', async () => {
  const root = await mkdtemp(join(tmpdir(), 'masc-effects-'))
  try {
    let current = editorCommand(newEditor(), 'note C4 0 1').editor
    const tracks = structuredClone(current.project.tracks)
    current = editorSound(current, dry())
    current = editorEffect(editorEffect(current, { kind: 'add', effect: effect('distortion') }), { kind: 'add', effect: effect('delay') })
    current = editorEffect(current, { kind: 'move', from: 1, to: 0 })
    assert.deepEqual(current.project.sound.effects.map(x => x.plugin.identifier), ['delay', 'distortion'])
    const path = join(root, 'phrase.json'); await saveProject(path, current.project)
    const reopened = (await loadProject(path)).project
    assert.deepEqual(reopened.sound, current.project.sound)
    assert.deepEqual(arrangementFromPhrase(reopened).project.assets[0].source.sound, current.project.sound)
    let source = editorSound(newEditor(importMidiSource(projectMidi(current.project))), dry())
    for (const insert of current.project.sound.effects) source = editorEffect(source, { kind: 'add', effect: insert })
    const sourcePath = join(root, 'source.json'); await saveProject(sourcePath, source.project)
    assert.deepEqual((await loadProject(sourcePath)).project.sound, current.project.sound)
    assert.deepEqual(arrangementFromMidiSource(source.project).project.assets[0].source.sound, current.project.sound)
    assert.deepEqual(current.project.tracks, tracks)
    current = editorEffect(current, { kind: 'remove', index: 0 })
    const previous = current.project.sound
    current = editorEffect(current, { kind: 'clear' })
    assert.deepEqual(current.project.sound, dry())
    assert.deepEqual(editorAction(current, { kind: 'undo' }).project.sound, previous)
    assert.deepEqual(editorAction(editorAction(current, { kind: 'undo' }), { kind: 'redo' }).project.sound, dry())
    assert.throws(() => editorEffect(current, { kind: 'remove', index: 0 }))
    assert.throws(() => editorEffect(newEditor(), { kind: 'add', effect: effect('delay') }))
    assert.equal(editorCommand(current, 'fx-add /Library/Audio/Plug-Ins/VST3/Soundtoys/EchoBoy Jr.vst3').effect.path, '/Library/Audio/Plug-Ins/VST3/Soundtoys/EchoBoy Jr.vst3')
    assert.deepEqual(editorCommand(current, 'fx-move 2 1').effect, { kind: 'fx-move', index: 1, to: 0 })
    for (const command of ['fx-edit 0', 'fx-remove -1', 'fx-move 1', 'fx-clear other']) assert.throws(() => editorCommand(current, command))
  } finally { await rm(root, { recursive: true, force: true }) }
})

test('effect edit owns previous preset and identity; native instrument replies are refused', async () => {
  const chosen = effect('delay'); let request, cancelled = 0
  const job = captureVstEffect(chosen.selection, { preset: chosen.preset, plugin: chosen.plugin, edit: true, run(value) {
    request = value
    return { promise: Promise.resolve({ plugin: { ...chosen.plugin, is_instrument: false }, preset: chosen.preset }), cancel() { cancelled++ } }
  } })
  assert.deepEqual(await job.promise, chosen)
  assert.deepEqual(request, { operation: 'effect_snapshot', ...chosen.selection, preset: chosen.preset, expected_plugin: chosen.plugin, edit: true })
  job.cancel(); assert.equal(cancelled, 1)
  await assert.rejects(captureVstEffect(chosen.selection, { run() { return { promise: Promise.resolve({ plugin: { is_instrument: true } }), cancel() {} } } }).promise, /audio effect/)
})

test('offline render forwards frozen ordered effects and refuses absent, reversed or foreign receipts', async () => {
  const root = await mkdtemp(join(tmpdir(), 'masc-effects-render-'))
  try {
    for (const observed of [undefined, [], wet().effects.map(effectIdentity).toReversed(), null, wet().effects.map(effectIdentity)]) {
      let request
      const sound = wet(), job = renderBoundVst(sound, { output_path: join(root, 'out.wav') }, { run(value) {
        request = value
        return { promise: Promise.resolve({ preset_sha256: sound.preset.sha256, effects: observed }), cancel() {} }
      } })
      if (JSON.stringify(observed) === JSON.stringify(sound.effects.map(effectIdentity))) await job.promise
      else await assert.rejects(job.promise, /effects do not match/)
      assert.deepEqual(request.effects, sound.effects)
      assert.notEqual(request.effects, sound.effects)
    }
    let sent
    await renderBoundVst(dry(), { output_path: join(root, 'dry.wav'), effects: wet().effects }, { run(request) {
      sent = request; return { promise: Promise.resolve({ preset_sha256: dry().preset.sha256 }), cancel() {} }
    } }).promise
    assert.equal(Object.hasOwn(sent, 'effects'), false)
  } finally { await rm(root, { recursive: true, force: true }) }
})

test('live child admits exactly the same ordered effect identities as offline rendering', async () => {
  for (const mode of ['valid', 'effects-missing', 'effects-reversed']) {
    const owner = openVstStream(wet(), { command: process.execPath, args: [fileURLToPath(new URL('./fixtures/vst-stream.mjs', import.meta.url)), mode] })
    try {
      if (mode === 'valid') { await owner.ready; assert.equal((await owner.render(7)).length, 56); owner.stop(); await owner.completion }
      else { await assert.rejects(owner.ready, /mismatch/); await assert.rejects(owner.completion) }
    } finally { owner.cancel(); await owner.completion.catch(() => {}) }
  }
})
