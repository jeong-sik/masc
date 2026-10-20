import { captureRange } from './capture-time.mjs'
import { recordingCorrectionCapture } from './recording-correction.mjs'

// A captured source keeps the complete native take, including opaque UMP and
// its timestamp origin. It is not a note-only MIDI source or an audio region.
export const capturePartNames = Object.freeze({ manifest: 'session.json', audio: 'audio.wav', audioBlocks: 'audio-blocks.jsonl', midi: 'midi.ump.jsonl' })
export function validateCaptureManifest(manifest) {
  const uint64 = value => {
    if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value) || BigInt(value) > 0xffffffffffffffffn) throw new Error('Invalid captured host time or count')
  }
  if (manifest?.schemaVersion !== 1 || !['recorded', 'failed'].includes(manifest.state)
      || manifest.audio !== capturePartNames.audio || manifest.audioBlocks !== capturePartNames.audioBlocks || manifest.midi !== capturePartNames.midi
      || !Number.isSafeInteger(manifest.sampleRate) || manifest.sampleRate <= 0
      || !Number.isSafeInteger(manifest.channels) || manifest.channels <= 0
      || typeof manifest.input?.id !== 'string' || !manifest.input.id || typeof manifest.input.name !== 'string'
      || !Array.isArray(manifest.midiSources) || manifest.midiSources.some(source => typeof source?.id !== 'string' || !source.id || typeof source.name !== 'string')
      || new Set(manifest.midiSources.map(source => source.id)).size !== manifest.midiSources.length
      || manifest.state === 'recorded' && manifest.failure != null
      || manifest.state === 'failed' && (typeof manifest.failure !== 'string' || !manifest.failure)) throw new Error('Invalid captured take manifest')
  const clock = manifest.clock
  if (clock?.kind !== 'mach-host-time' || !Number.isSafeInteger(clock.numer) || clock.numer <= 0
      || !Number.isSafeInteger(clock.denom) || clock.denom <= 0) throw new Error('Invalid captured host clock')
  uint64(clock.requestedStart); uint64(manifest.audioFrames); uint64(manifest.midiPacketCount)
  if (clock.firstAudioHostTime !== null) uint64(clock.firstAudioHostTime)
  if ((BigInt(manifest.audioFrames) > 0n) !== (clock.firstAudioHostTime !== null)) throw new Error('Captured audio origin disagrees with frame total')
  return manifest
}
export function validateCapturedSourceParts(asset) {
  if (asset?.kind !== 'capture' || !asset.parts || Object.keys(asset.parts).length !== Object.keys(capturePartNames).length) throw new Error('Invalid captured source parts')
  for (const role of Object.keys(capturePartNames)) {
    const part = asset.parts[role]
    const suffix = role === 'audio' ? 'wav' : 'capture'
    if (typeof part?.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(part.sha256)
        || part.file !== `assets/${part.sha256}.${suffix}`) throw new Error('Invalid captured source identity/path')
  }
  validateCaptureManifest(asset.manifest)
  if (asset.recording?.correction !== undefined) recordingCorrectionCapture(asset.recording.correction, asset.manifest)
  return asset
}
export function validateCapturedSource(asset) {
  validateCapturedSourceParts(asset)
  captureRange(asset)
  return asset
}
