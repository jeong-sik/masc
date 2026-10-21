import { validateSound } from './project-sound.mjs'
import { openSynthStream } from './synth-stream.mjs'

// The audio consumer owns the clock. No speculative queue or device is opened.
export function openVstStream(sound, { sampleRate = 44100, signal,
  command = 'masc-vst-host', args = [], spawnProcess } = {}) {
  validateSound(sound)
  if (sound.kind !== 'vst') throw new Error('Choose a project-bound VST sound')
  if (!Number.isInteger(sampleRate) || sampleRate <= 0 || sampleRate > 0xffffffff) throw new Error('Invalid VST stream sample rate')
  sound = structuredClone(sound)
  return openSynthStream({ command, args: [...args, '--stream'], spawnProcess, signal, label: 'VST',
    opening: { kind: 'open', schemaVersion: 1, sampleRate,
      plugin_path: sound.selection.plugin_path, plugin_name: sound.selection.plugin_name,
      instrument: { identifier: sound.instrument.identifier, version: sound.instrument.version },
      preset: { data: sound.preset.data, sha256: sound.preset.sha256 } },
    acknowledge: event => event.instrument?.identifier === sound.instrument.identifier
      && event.instrument?.version === sound.instrument.version && event.preset_sha256 === sound.preset.sha256,
  })
}
