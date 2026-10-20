import { fraction } from './exact-time.mjs'

const maximum = 0xffffffffffffffffn
function counter(value) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value) || BigInt(value) > maximum) throw new Error('Invalid render host/frame counter')
  return BigInt(value)
}
function timebase(value) {
  if (value?.kind !== 'mach-host-time' || ![value.numer, value.denom].every(number =>
    Number.isInteger(number) && number > 0 && number <= 0xffffffff)) throw new Error('Invalid render/MIDI host timebase')
  return { numer: BigInt(value.numer), denom: BigInt(value.denom) }
}
export function validateRenderClock(value) {
  if (value?.kind !== 'clock' || value.schemaVersion !== 1 || typeof value.device?.id !== 'string' || !value.device.id
      || typeof value.device.name !== 'string' || !Number.isInteger(value.sampleRate) || value.sampleRate <= 0
      || value.sampleRate > 0xffffffff || !value.anchor) throw new Error('Invalid source-render clock')
  timebase(value.clock)
  counter(value.anchor.frame)
  if (counter(value.anchor.hostTime) === 0n) throw new Error('Missing source-render host time')
  return value
}

// Preserve original host ticks. This is an exact rational projection at the
// declared nominal output rate, not physical latency/drift compensation.
export function nominalMidiFrame(hostTime, midiClock, renderClock) {
  validateRenderClock(renderClock)
  const input = timebase(midiClock), output = timebase(renderClock.clock)
  if (input.numer * output.denom !== output.numer * input.denom) throw new Error('MIDI/output host timebases disagree')
  const d = output.denom * 1_000_000_000n
  const delta = counter(hostTime) - counter(renderClock.anchor.hostTime)
  return fraction(counter(renderClock.anchor.frame) * d + delta * output.numer * BigInt(renderClock.sampleRate), d)
}
