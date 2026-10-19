import { test } from 'node:test'
import assert from 'node:assert/strict'
import { InstrumentPicker, selectionLabel, presetLabel, pickerActions } from '../instruments.mjs'

const instrument = { plugin_path: '/synth.vst3', plugin_name: null, name: 'Retrologue' }

function pickerWith(readActive) {
  return new InstrumentPicker({ directory: '/tmp', notify() {}, selected() {}, soundfont() {},
    failed() {}, active: readActive, run() { return { promise: Promise.resolve({}), cancel() {} } } })
}

test('the selection label names the live instrument and sound', () => {
  assert.equal(selectionLabel(null), 'SoundFont')
  assert.equal(selectionLabel({ ...instrument, preset_path: null }), 'Retrologue · default state')
  assert.equal(selectionLabel({ ...instrument, preset_path: '/presets/Warm Pad.vstpreset' }),
    'Retrologue · Warm Pad')
  assert.equal(presetLabel('/presets/Bass.VSTPRESET'), 'Bass')
})

test('the picker advertises only the actions its keys reach', () => {
  const keys = view => pickerActions(view).map(action => action.key)
  const enterLabel = view => pickerActions(view).find(action => action.key === 'Enter')?.label

  const plugins = keys({ kind: 'plugins' })
  assert.ok(plugins.includes('Enter') && plugins.includes('/') && plugins.includes('Esc'))
  assert.ok(!plugins.includes('e') && !plugins.includes('p'))
  assert.equal(enterLabel({ kind: 'plugins' }), 'select')

  const presets = keys({ kind: 'presets' })
  assert.ok(presets.includes('e') && presets.includes('p') && presets.includes('Enter'))
  assert.equal(enterLabel({ kind: 'presets' }), 'play')

  assert.deepEqual(keys({ kind: 'loading' }), ['Esc'])
  assert.deepEqual(keys({ kind: 'preset_path' }), ['Enter', 'Esc'])
  assert.deepEqual(pickerActions(null), [])
})

test('the picker marks the row matching the live selection', () => {
  let active = null
  const picker = pickerWith(() => active)

  const soundfont = { kind: 'soundfont', name: 'SoundFont (built-in player)' }
  const bundle = { name: 'Retrologue', plugin_path: instrument.plugin_path }
  const other = { name: 'Padshop', plugin_path: '/padshop.vst3' }

  assert.equal(picker.isActive(soundfont), true)
  assert.equal(picker.isActive(bundle), false)

  active = { ...instrument, preset_path: '/presets/Warm Pad.vstpreset' }
  assert.equal(picker.isActive(soundfont), false)
  assert.equal(picker.isActive(bundle), true)
  assert.equal(picker.isActive(other), false)

  const sub = { ...bundle, plugin_name: 'Second', name: 'Second' }
  assert.equal(picker.isActive(sub), false, 'a different sub-instrument is not active')
  active = { ...instrument, plugin_name: 'Second', name: 'Second', preset_path: null }
  assert.equal(picker.isActive(sub), true)
  assert.equal(picker.isActive(bundle), true, 'the containing bundle still owns the live instrument')

  const defaultState = { ...instrument, name: 'Default instrument state', preset_path: null }
  const saved = { ...instrument, name: 'Warm Pad.vstpreset', preset_path: '/presets/Warm Pad.vstpreset' }
  active = { ...instrument, preset_path: null }
  assert.equal(picker.isActive(defaultState), true)
  assert.equal(picker.isActive(saved), false)
  active = { ...instrument, preset_path: '/presets/Warm Pad.vstpreset' }
  assert.equal(picker.isActive(saved), true)
  assert.equal(picker.isActive(defaultState), false)
})

test('a sound marker never crosses instruments or sub-instruments', () => {
  let active = { ...instrument, preset_path: null }
  const picker = pickerWith(() => active)

  const otherDefault = { plugin_path: '/padshop.vst3', plugin_name: null, name: 'Padshop' }
  assert.equal(picker.isActive({ ...otherDefault, name: 'Default instrument state', preset_path: null }),
    false, 'another instrument default state is not the live sound')

  const first = { plugin_path: instrument.plugin_path, plugin_name: 'First', name: 'First' }
  const second = { plugin_path: instrument.plugin_path, plugin_name: 'Second', name: 'Second' }
  active = { ...first, preset_path: null }
  assert.equal(picker.isActive({ ...second, name: 'Default instrument state', preset_path: null }),
    false, 'a sibling sub-instrument default state is not the live sound')
  assert.equal(picker.isActive({ ...first, name: 'Default instrument state', preset_path: null }), true)

  active = { ...second, preset_path: '/presets/Warm Pad.vstpreset' }
  const sibling = { ...first, name: 'Warm Pad.vstpreset', preset_path: '/presets/Warm Pad.vstpreset' }
  assert.equal(picker.isActive(sibling), false, 'a preset is not active under a sibling sub-instrument')
})
