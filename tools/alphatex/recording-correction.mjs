import { validateCapturePlacement } from './capture-placement.mjs'
import { validateCalibrationCapture } from './calibration-profile.mjs'

export function validateRecordingCorrection(value) {
  if (value?.kind === 'none' && Object.keys(value).length === 1) return value
  if (value?.kind !== 'audio' || Object.keys(value).length !== 5
      || typeof value.input !== 'string' || !value.input || typeof value.output !== 'string' || !value.output
      || !value.audioChannel || Object.keys(value.audioChannel).length !== 2
      || ![value.audioChannel.input, value.audioChannel.output].every(n => Number.isSafeInteger(n) && n > 0 && n <= 0xffffffff)) throw new Error('Invalid recording correction selection')
  validateCapturePlacement(value.placement)
  if (value.placement.kind === 'calibrated') {
    const profile = value.placement.profile
    if (value.input !== profile.input.id || value.output !== profile.output.id
        || value.audioChannel.input !== profile.input.channel || value.audioChannel.output !== profile.output.channel) throw new Error('Recording correction differs from its measured route')
  }
  return value
}
export function recordingCorrectionContext(value, { input, output, monitorOutput, playback } = {}) {
  validateRecordingCorrection(value)
  if (value.kind === 'none') return
  if (value.input !== input || value.output !== output || playback && (playback.device?.id !== output
      || !Number.isSafeInteger(playback.device.outputs) || playback.device.outputs < 1 || value.audioChannel.output > playback.device.outputs)) throw new Error('Recording correction input or playback route changed')
  if (value.placement.kind === 'calibrated') {
    const profile = value.placement.profile
    if (monitorOutput || playback && (playback.clock?.sampleRate !== profile.output.sampleRate
        || playback.clock?.bufferFrames !== profile.output.bufferFrames)) throw new Error('Measured recording correction requires matching unmonitored output rate and buffer size')
  }
}
export function recordingCorrectionCapture(value, manifest) {
  validateRecordingCorrection(value)
  if (value.kind === 'none') return
  if (manifest.input?.id !== value.input || !Number.isSafeInteger(manifest.channels) || manifest.channels < 1 || value.audioChannel.input > manifest.channels) throw new Error('Recorded input differs from the correction selection')
  if (value.placement.kind === 'calibrated') validateCalibrationCapture(value.placement.profile,
    { kind: 'capture', manifest }, { component: 'audio', audioChannel: value.audioChannel }, value.output)
}
