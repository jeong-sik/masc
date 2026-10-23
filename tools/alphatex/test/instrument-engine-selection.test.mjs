import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { InstrumentPicker } from '../instruments.mjs'

// This checks requested sound identities and retained selection, not menu text or layout.
test('explicit SoundFont engine selection reaches its caller and keeps the active engine distinct from VST', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'masc-sound-engine-'))
  const selections = [], failures = [], choices = [
    { kind: 'soundfont', engine: 'fluidsynth', name: 'Native sound' },
    { kind: 'soundfont', engine: 'alphasynth', name: 'Built-in sound' }]
  let active = { kind: 'soundfont' }
  const picker = new InstrumentPicker({ directory, notify() {}, selected() { assert.fail('Unexpected VST selection') },
    soundfont: engine => selections.push(engine), soundfontChoices: choices, failed: error => failures.push(error), active: () => active,
    run() { return { promise: Promise.resolve({ candidates: [] }), cancel() {} } } })
  try {
    await picker.open()
    assert.equal(picker.isActive(choices[0]), false); assert.equal(picker.isActive(choices[1]), true)
    picker.view.cursor = picker.items().findIndex(item => item.engine === 'fluidsynth')
    await picker.choose(); assert.deepEqual(selections, ['fluidsynth'])
    active = { kind: 'soundfont', engine: { kind: 'fluidsynth' } }
    assert.equal(picker.isActive(choices[0]), true); assert.equal(picker.isActive(choices[1]), false)
    assert.equal(picker.isActive({ plugin_path: '/instrument.vst3' }), false)
    assert.equal(failures.length, 0)
  } finally { picker.close(); await picker.settled(); await rm(directory, { recursive: true, force: true }) }
})

test('VST discovery failure retains the explicitly available engine choices without selecting a replacement', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'masc-sound-engine-'))
  const choices = [{ kind: 'soundfont', engine: 'fluidsynth', name: 'Native sound' }], selected = [], failures = []
  const picker = new InstrumentPicker({ directory, notify() {}, selected: sound => selected.push(sound),
    soundfont: engine => selected.push(engine), soundfontChoices: choices, failed: error => failures.push(error),
    run() { return { promise: Promise.reject(new Error('Host unavailable')), cancel() {} } } })
  try {
    await picker.open()
    assert.deepEqual(selected, []); assert.equal(failures.length, 1)
    assert.equal(picker.items().find(item => item.engine === 'fluidsynth')?.engine, 'fluidsynth')
    await picker.choose(); assert.deepEqual(selected, ['fluidsynth'])
  } finally { picker.close(); await picker.settled(); await rm(directory, { recursive: true, force: true }) }
})
