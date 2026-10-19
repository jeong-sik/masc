function integer(value, minimum = 0) {
  if (!Number.isSafeInteger(value) || value < minimum) throw new Error('Invalid calibration sample or channel')
}
function host(value) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value) || BigInt(value) > 0xffffffffffffffffn) throw new Error('Invalid calibration host clock')
  return BigInt(value)
}
export function calibrationFraction(n, d) {
  let a = n < 0n ? -n : n, b = d
  while (b) [a, b] = [b, a % b]
  return { numerator: String(n / a), denominator: String(d / a) }
}
export function calibrationResidual(profile, pulse) {
  const { numer, denom, anchor } = profile.clock, rate = BigInt(profile.input.sampleRate)
  return calibrationFraction((host(pulse.blockHostTime) - host(anchor)) * BigInt(numer) * rate
    + BigInt(pulse.localFrame - pulse.pulseFrame) * 1_000_000_000n * BigInt(denom), BigInt(denom) * rate)
}
export function calibrationMilliseconds(profile, pulse) {
  const value = calibrationResidual(profile, pulse)
  return Number(value.numerator) / Number(value.denominator) / 1e6
}
export function validateCalibrationProfile(profile) {
  if (profile?.schemaVersion !== 1 || profile.kind !== 'audio-calibration-profile'
      || Object.keys(profile).length !== 8 || !Number.isFinite(profile.maxLagMs) || profile.maxLagMs <= 0
      || Object.keys(profile.experiment ?? {}).sort().join(',') !== 'blocks,manifest,measurement,midi,playback,reference,wave'
      || Object.values(profile.experiment).some(value => typeof value !== 'string' || !/^[a-f0-9]{64}$/.test(value))) throw new Error('Invalid calibration evidence identity')
  for (const side of [profile.input, profile.output]) {
    if (typeof side?.id !== 'string' || !side.id) throw new Error('Invalid calibration device identity')
    integer(side.channel, 1)
    if (!Number.isFinite(side.sampleRate) || side.sampleRate <= 0) throw new Error('Invalid calibration sample rate')
  }
  if (Object.keys(profile.input).length !== 4 || Object.keys(profile.output).length !== 4 || Object.keys(profile.clock ?? {}).length !== 3
      || profile.input.monitoring !== 'off') throw new Error('Calibration requires an unmonitored capture and exact device context')
  integer(profile.input.sampleRate, 1); integer(profile.output.renderQuantum, 1)
  if (profile.output.renderQuantum > 0xffffffff) throw new Error('Calibration render quantum exceeds the native frame range')
  integer(profile.clock?.numer, 1); integer(profile.clock.denom, 1); host(profile.clock.anchor)
  if (!Array.isArray(profile.pulses) || profile.pulses.length !== 2) throw new Error('Calibration requires both experiment pulses')
  for (const pulse of profile.pulses) {
    if (!pulse || Object.keys(pulse).length !== 6) throw new Error('Invalid calibration pulse evidence')
    integer(pulse.pulseFrame); integer(pulse.frame); integer(pulse.localFrame)
    const offset = host(pulse.blockFrameOffset); host(pulse.blockHostTime)
    if (BigInt(pulse.frame) !== offset + BigInt(pulse.localFrame) || !Number.isFinite(pulse.correlation) || Math.abs(pulse.correlation) > 1) throw new Error('Invalid calibration pulse provenance')
    calibrationResidual(profile, pulse)
  }
  return profile
}
export function validateCalibrationCapture(profile, asset, clip, output) {
  validateCalibrationProfile(profile)
  if (asset?.kind !== 'capture' || clip.component !== 'audio' || !clip.audioChannel
      || asset.manifest.input.id !== profile.input.id || asset.manifest.sampleRate !== profile.input.sampleRate
      || asset.manifest.monitoring?.state !== 'off' || clip.audioChannel.input !== profile.input.channel
      || clip.audioChannel.output !== profile.output.channel || output !== undefined && output !== profile.output.id) {
    throw new Error('Calibration does not match the selected unmonitored audio component, device or channels')
  }
}
