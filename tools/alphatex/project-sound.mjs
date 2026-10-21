import { createHash } from 'node:crypto'
import { isDeepStrictEqual } from 'node:util'

export function validateVstSelection(value) {
  if (!value || typeof value !== 'object' || typeof value.plugin_path !== 'string' || !value.plugin_path
      || typeof value.name !== 'string' || !value.name
      || !(value.plugin_name === null || typeof value.plugin_name === 'string')
      || !(value.preset_path === null || typeof value.preset_path === 'string')) {
    throw new Error('Saved VST selection is invalid; select an instrument again to replace it')
  }
  return { plugin_path: value.plugin_path, plugin_name: value.plugin_name, preset_path: value.preset_path, name: value.name }
}

// The document owns actual preset bytes, including the captured default state.
// The original path is a label; playback never reads that mutable path again.
export function validateSound(sound) {
  if (sound?.kind === 'soundfont' && Object.keys(sound).length === 1) return sound
  if (sound?.kind === 'soundfont' && sound.engine?.kind === 'fluidsynth') {
    if (Object.keys(sound).some(key => !['kind', 'engine', 'font', 'bankStyle'].includes(key))
      || Object.keys(sound.engine).some(key => !['kind', 'version', 'controlFrames'].includes(key))
      || typeof sound.engine.version !== 'string' || !sound.engine.version
      || !Number.isSafeInteger(sound.engine.controlFrames) || sound.engine.controlFrames <= 0
      || !['gm', 'gs', 'xg', 'mma'].includes(sound.bankStyle)
      || !sound.font || Object.keys(sound.font).some(key => !['name', 'data', 'sha256'].includes(key))
      || typeof sound.font.name !== 'string' || !sound.font.name || typeof sound.font.data !== 'string') throw new Error('Invalid bound SoundFont')
    const bytes = Buffer.from(sound.font.data, 'base64')
    if (!bytes.length || bytes.toString('base64') !== sound.font.data
      || createHash('sha256').update(bytes).digest('hex') !== sound.font.sha256
      || bytes.toString('ascii', 0, 4) !== 'RIFF' || bytes.toString('ascii', 8, 12) !== 'sfbk') throw new Error('Bound SF2 content changed')
    return sound
  }
  if (sound?.kind !== 'vst' || Object.keys(sound).some(key => !['kind', 'selection', 'preset', 'instrument'].includes(key))) throw new Error('Invalid project sound')
  const selection = validateVstSelection(sound.selection)
  if (Object.keys(sound.selection).some(key => !(key in selection))) throw new Error('Invalid project VST selection fields')
  const bytes = Buffer.from(sound.preset?.data ?? '', 'base64')
  if (!bytes.length || bytes.toString('base64') !== sound.preset?.data
      || createHash('sha256').update(bytes).digest('hex') !== sound.preset.sha256) throw new Error('Project VST preset content changed')
  if (typeof sound.instrument?.identifier !== 'string' || !sound.instrument.identifier
      || typeof sound.instrument.version !== 'string' || !sound.instrument.version) throw new Error('Invalid project VST identity')
  return sound
}

// Receipt identity excludes private preset/font payloads. Display names do not
// certify a sound; both capture retirement and source admission use this match.
export function soundIdentity(sound) {
  if (sound?.kind === 'vst') return { name: sound.selection.name, identifier: sound.instrument.identifier,
    version: sound.instrument.version, presetSHA256: sound.preset.sha256 }
  if (sound?.kind === 'soundfont' && sound.engine?.kind === 'fluidsynth') return {
    kind: 'soundfont', name: sound.font.name, engine: { ...sound.engine },
    bankStyle: sound.bankStyle, fontSHA256: sound.font.sha256, timing: 'control-block-ceil',
  }
  throw new Error('Choose a project-bound VST or FluidSynth sound')
}
export function soundIdentityMatches(sound, observed) {
  if (sound?.kind === 'vst' && observed?.kind !== undefined) return false
  const { name, ...expected } = soundIdentity(sound)
  return Object.entries(expected).every(([key, value]) => isDeepStrictEqual(observed?.[key], value))
}
