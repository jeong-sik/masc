import { validateRenderClock } from './render-midi-clock.mjs'
import { exactSeconds } from './exact-time.mjs'

export const practicePartNames = Object.freeze({ receipt: 'take.json', context: 'context.json', arm: 'armed.json', events: 'events.jsonl' })
export function practiceUnsigned(value, maximum = 0xffffffffffffffffn) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value) || BigInt(value) > maximum) throw new Error('Invalid practice host/frame/packet counter')
  return BigInt(value)
}
export function validatePracticeMetadata(value) {
  validateRenderClock(value?.renderClock)
  const input = value.input
  if (input?.kind !== 'midi-input' || input.schemaVersion !== 1 || input.protocol !== 2
      || typeof input.source?.id !== 'string' || !Number.isInteger(Number(input.source.id))
      || String(Number(input.source.id)) !== input.source.id || Number(input.source.id) < -2147483648 || Number(input.source.id) > 2147483647
      || typeof input.source.name !== 'string') throw new Error('Invalid practice MIDI source')
  const clock = input.clock, output = value.renderClock.clock
  if (clock?.kind !== 'mach-host-time' || ![clock.numer, clock.denom].every(n => Number.isInteger(n) && n > 0 && n <= 0xffffffff)
      || BigInt(clock.numer) * BigInt(output.denom) !== BigInt(output.numer) * BigInt(clock.denom)) throw new Error('Practice host timebases disagree')
  const count = practiceUnsigned(value.packets), frames = practiceUnsigned(value.renderedFrames)
  if (frames < practiceUnsigned(value.renderClock.anchor.frame)) throw new Error('Practice render total precedes its anchor')
  if (!value.midiTime || Object.keys(value.midiTime).length !== 2) throw new Error('Invalid practice MIDI bounds')
  const { first, last } = value.midiTime
  if ((first === null) !== (last === null) || (count > 0n) !== (first !== null)
      || first !== null && practiceUnsigned(first) > practiceUnsigned(last)) throw new Error('Practice packet count disagrees with its time bounds')
  return value
}
export function practiceRange(asset) {
  const meta = validatePracticeMetadata(asset.metadata), render = meta.renderClock
  const anchor = practiceUnsigned(render.anchor.hostTime), first = meta.midiTime.first === null ? anchor : practiceUnsigned(meta.midiTime.first)
  const origin = first < anchor ? first : anchor, frames = practiceUnsigned(meta.renderedFrames) - practiceUnsigned(render.anchor.frame)
  const n = frames * 1_000_000_000n * BigInt(render.clock.denom), d = BigInt(render.sampleRate) * BigInt(render.clock.numer)
  const renderEnd = anchor + (n + d - 1n) / d
  const midiEnd = meta.midiTime.last === null ? anchor : practiceUnsigned(meta.midiTime.last) + 1n
  return { origin: String(origin), extent: String((renderEnd > midiEnd ? renderEnd : midiEnd) - origin) }
}
export function practiceRegionTime(asset, { offset, extent, sourceDivisor }) {
  const range = practiceRange(asset), clock = asset.metadata.renderClock.clock
  // Native region spans use UInt128; absolute packet timestamps stay UInt64.
  const start = practiceUnsigned(offset, (1n << 128n) - 1n), length = practiceUnsigned(extent, (1n << 128n) - 1n)
  const subdivision = sourceDivisor === undefined ? 1n : practiceUnsigned(sourceDivisor, (1n << 128n) - 1n)
  if (!subdivision || !length || start + length > BigInt(range.extent) * subdivision) throw new Error('Practice region exceeds its source host-clock span')
  const denominator = BigInt(clock.denom) * subdivision
  const sourceStartSeconds = exactSeconds(start * BigInt(clock.numer), denominator)
  const sourceEndSeconds = exactSeconds((start + length) * BigInt(clock.numer), denominator)
  const durationSeconds = exactSeconds(length * BigInt(clock.numer), denominator)
  if (sourceEndSeconds <= sourceStartSeconds || durationSeconds <= 0) throw new Error('Practice region time is not representable')
  return { sourceStartSeconds, sourceEndSeconds, durationSeconds,
    sourceClock: { origin: range.origin, offset, extent, numer: clock.numer, denom: clock.denom,
      ...(sourceDivisor === undefined ? {} : { sourceDivisor }) }, audio: null }
}
export function validatePracticeSource(asset) {
  if (asset?.kind !== 'practice' || !asset.parts || Object.keys(asset.parts).length !== Object.keys(practicePartNames).length) throw new Error('Invalid practice source parts')
  for (const role of Object.keys(practicePartNames)) {
    const part = asset.parts[role]
    if (typeof part?.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(part.sha256)
        || part.file !== `assets/${part.sha256}.practice`) throw new Error('Invalid practice source identity/path')
  }
  practiceRange(asset)
  if (asset.metadata.packets === '0') throw new Error('Practice source contains no MIDI packets to arrange')
  return asset
}
