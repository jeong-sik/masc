import test from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtemp, readdir, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { newEditor, editorCommand, editorSound } from '../sequencer-editor.mjs'
import { arrangementFromPhrase } from '../phrase-arrangement.mjs'
import { editArrangement, newArrangement } from '../arrangement.mjs'
import { arrangementVstMidiPlan, prepareArrangementVstMidi } from '../arrangement-vst.mjs'
import { importMidiSource, exportMidiSource, midiSourcePattern } from '../midi-source.mjs'
import { arrangementEditor, arrangementSound, arrangementAction } from '../arrangement-editor.mjs'

const bytes = Buffer.from('owned preset')
const sound = { kind: 'vst', selection: { plugin_path: '/chosen.vst3', plugin_name: null, preset_path: null, name: 'Chosen' },
  preset: { data: bytes.toString('base64'), sha256: createHash('sha256').update(bytes).digest('hex') },
  instrument: { identifier: 'chosen-id', version: '1.0' } }
function phrase() {
  let editor = newEditor()
  for (const command of ['tempo 120', 'length 8', 'note C3 0 4 96']) editor = editorCommand(editor, command).editor
  return arrangementFromPhrase(editorSound(editor, sound).project).project
}

test('VST preparation retains owned phrase sound and original port expression without choosing physical destinations', () => {
  const project = phrase(), before = structuredClone(project), source = exportMidiSource(project.assets[0].source)
  const prepared = arrangementVstMidiPlan(project)
  assert.equal(prepared.plan.kind, 'vst-arrangement')
  assert.equal(prepared.plan.duration, 4)
  assert.equal(prepared.plan.regions.length, 1)
  assert.deepEqual(prepared.sounds.map(value => value.sound), [sound])
  assert.equal(prepared.plan.sources.length, 1)
  assert.ok(prepared.plan.sources[0].events.some(event => event.bytes[0] === 0x90))
  assert.ok(!('bindings' in prepared.plan.sources[0]))
  assert.deepEqual(exportMidiSource(project.assets[0].source), source)
  assert.deepEqual(project, before)
})

test('arrangement instrument selection updates owned phrase/source together and undo restores both without rewriting MIDI', () => {
  const project = phrase(), before = structuredClone(project)
  const source = exportMidiSource(project.assets[0].source), editor = arrangementEditor(project)
  const changed = structuredClone(sound); changed.selection.name = 'Another owned sound'
  const selected = arrangementSound(editor, project.assets[0].id, changed)
  assert.deepEqual(selected.project.assets[0].source.sound, changed)
  assert.deepEqual(selected.project.assets[0].phrase.sound, changed)
  assert.deepEqual(exportMidiSource(selected.project.assets[0].source), source)
  changed.selection.name = 'External mutation'
  assert.equal(selected.project.assets[0].source.sound.selection.name, 'Another owned sound')
  assert.deepEqual(arrangementAction(selected, { kind: 'undo' }).project, before)
  assert.deepEqual(project, before)
  assert.throws(() => arrangementSound(editor, 'missing', sound), /Select a MIDI/)
  assert.throws(() => arrangementSound(editor, project.assets[0].id, { kind: 'soundfont' }), /Choose a VST/)
})

test('loop audition projects the authored window into finite partial copies on its exact original source clock', () => {
  let project = phrase()
  project = editArrangement(project, { kind: 'region-change', id: 'region-1', extent: 1920, repeat: 4 })
  project = editArrangement(project, { kind: 'loop', range: { start: 1440, end: 6240 } })
  const before = structuredClone(project), selected = arrangementVstMidiPlan(project)
  assert.equal(selected.loop, true)
  assert.equal(selected.originSeconds, 0.75)
  assert.equal(selected.plan.duration, 2.5)
  assert.deepEqual(selected.plan.regions.map(region => [region.startSeconds, region.sourceStart, region.sourceEnd, region.repeatCount]),
    [[0, 0.75, 1, 1], [0.25, 0, 1, 2], [2.25, 0, 0.25, 1]])
  assert.deepEqual(project, before)
})

test('independent source ports and selected SMF2/SMPTE clocks stay distinct for native instrument instances', () => {
  const chunk = (name, data) => {
    const header = Buffer.alloc(8); header.write(name); header.writeUInt32BE(data.length, 4)
    return Buffer.concat([header, Buffer.from(data)])
  }
  const header = Buffer.alloc(6); header.writeUInt16BE(2); header.writeUInt16BE(2, 2); header.writeUInt16BE(0xe350, 4)
  const track = port => [0, 255, 33, 1, port, 0, 0xe0, 0, 65, 0, 0x90, 60 + port, 90, 0x83, 0x60, 0x80, 60 + port, 77, 0, 255, 47, 0]
  const source = importMidiSource(Buffer.concat([chunk('MThd', header), chunk('MTrk', track(1)), chunk('MTrk', track(2))]), { sound })
  let project = editArrangement(newArrangement(), { kind: 'asset-add', asset: { id: 'original', kind: 'midi', name: 'Original', source } })
  project = editArrangement(project, { kind: 'lane-add', sourceKind: 'midi', name: 'Keys' })
  project = editArrangement(project, { kind: 'region-add', lane: 'lane-1', asset: 'original', name: 'Chosen pattern',
    position: 0, offset: 0, extent: 480, repeat: 1, pattern: 1 })
  const selected = arrangementVstMidiPlan(project)
  assert.deepEqual([...new Set(selected.plan.sources[0].events.map(event => event.port))], [2])
  assert.equal(selected.plan.sources[0].duration, midiSourcePattern(source, { pattern: 1 }).seconds)
  assert.ok(selected.plan.sources[0].events.some(event => event.bytes[0] === 0x80 && event.bytes[2] === 77))
  assert.equal(selected.plan.sources[0].id, '["original",1]')
})

test('unselected or explicit SoundFont sound never becomes an automatic VST fallback; cancelled work creates no files', async () => {
  const missing = phrase()
  delete missing.assets[0].source.sound; delete missing.assets[0].phrase.sound
  assert.throws(() => arrangementVstMidiPlan(missing), /Choose a VST sound/)
  const explicit = phrase()
  explicit.assets[0].source.sound = explicit.assets[0].phrase.sound = { kind: 'soundfont' }
  assert.throws(() => arrangementVstMidiPlan(explicit), /Choose a VST sound/)
  const root = await mkdtemp(join(tmpdir(), 'masc-vst-cancel-'))
  try {
    const controller = new AbortController(); controller.abort()
    await assert.rejects(prepareArrangementVstMidi(phrase(), { directory: root, signal: controller.signal }), { name: 'AbortError' })
    assert.deepEqual(await readdir(root), [])
  } finally { await rm(root, { recursive: true, force: true }) }
})
