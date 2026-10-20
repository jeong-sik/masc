import { createHash } from 'node:crypto'

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
