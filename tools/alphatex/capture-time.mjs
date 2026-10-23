// Captured regions use the original host-clock tick domain. Absolute UInt64
// origins and source frame counts never pass through Number. Only derived
// display/scheduling seconds cross that boundary.
import { binary } from './exact-time.mjs'

const uint64Max = 0xffffffffffffffffn
function unsigned(value, name, maximum) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value)) throw new Error(`Invalid captured ${name}`)
  const number = BigInt(value)
  if (maximum !== undefined && number > maximum) throw new Error(`Invalid captured ${name}`)
  return number
}
function ceil(numerator, denominator) {
  const quotient = numerator / denominator, remainder = numerator % denominator
  return quotient + (remainder > 0n ? 1n : 0n)
}
function floor(numerator, denominator) {
  const quotient = numerator / denominator, remainder = numerator % denominator
  return quotient - (remainder < 0n ? 1n : 0n)
}
function seconds(numerator, denominator) {
  const value = Number(numerator / denominator) + Number(numerator % denominator) / Number(denominator)
  if (!Number.isFinite(value)) throw new Error('Captured source time is not representable')
  return value
}
function clockOf(manifest) {
  const { numer, denom } = manifest.clock
  if (![numer, denom, manifest.sampleRate].every(value => Number.isSafeInteger(value) && value > 0)) throw new Error('Invalid captured timebase or sample rate')
  return { numer: BigInt(numer), denom: BigInt(denom), rate: BigInt(manifest.sampleRate) }
}
// Terminal seconds enter as decimal rationals. Quantize once at the native
// host-clock boundary: nearest whole tick, exact half ties away from zero.
function decimalInput(text, unit) {
  const match = typeof text === 'string' && /^([+-]?)(?:(\d+)(?:\.(\d+))?|\.(\d+))$/.exec(text)
  if (!match) throw new Error(`Use decimal ${unit} without exponents`)
  const digits = match[3] ?? match[4] ?? '', divisor = 10n ** BigInt(digits.length)
  const value = BigInt(match[2] ?? '0') * divisor + BigInt(digits || '0')
  return [match[1] === '-' ? -value : value, divisor]
}
function sourceTicks(asset, value, divisor) {
  const clock = clockOf(asset.manifest), negative = value < 0n
  const numerator = (negative ? -value : value) * 1_000_000_000n * clock.denom, denominator = divisor * clock.numer
  const ticks = numerator / denominator + (2n * (numerator % denominator) >= denominator ? 1n : 0n)
  return negative ? -ticks : ticks
}
export function captureSecondsToTicks(asset, text) {
  return sourceTicks(asset, ...decimalInput(text, 'seconds'))
}
// Beats are project quarter notes, not captured Flex Data tempo or clip-local
// timing. Match the exact binary64 project tempo used by native scheduling.
export function captureBeatsToTicks(asset, text, tempo) {
  if (tempo === undefined) throw new Error('Beat editing requires the arrangement tempo')
  const ratio = typeof text === 'string' && /^([+-]?\d+)\/(\d+)$/.exec(text)
  const [value, divisor] = ratio ? [BigInt(ratio[1]), BigInt(ratio[2])] : decimalInput(text, 'beats')
  if (divisor === 0n) throw new Error('Beat fractions need a positive denominator')
  const [tempoN, tempoD] = binary(tempo)
  return sourceTicks(asset, value * 60n * tempoD, divisor * tempoN)
}
// The editor's zero belongs to the recorded source, not the moving edge of an
// authored overlay. Derived imports keep their declared original source span.
export function captureHostAtSeconds(asset, text) {
  return hostAtTicks(asset, captureSecondsToTicks(asset, text))
}
export function captureHostAtBeats(asset, text, tempo) {
  return hostAtTicks(asset, captureBeatsToTicks(asset, text, tempo))
}
function hostAtTicks(asset, ticks) {
  const origin = BigInt(captureRange({ ...asset, ump: undefined }).origin)
  return String(unsigned(String(origin + ticks), 'authored MIDI time', uint64Max))
}
export function captureSecondsAtHost(asset, hostTime) {
  const origin = BigInt(captureRange({ ...asset, ump: undefined }).origin), clock = clockOf(asset.manifest)
  return seconds((unsigned(hostTime, 'event host time', uint64Max) - origin) * clock.numer, 1_000_000_000n * clock.denom)
}
export function captureRange(asset) {
  const manifest = asset.manifest, clock = clockOf(manifest), frames = unsigned(manifest.audioFrames, 'frame total', uint64Max)
  let origin = unsigned(manifest.clock.requestedStart, 'clock origin', uint64Max)
  const firstAudio = manifest.clock.firstAudioHostTime === null ? null : unsigned(manifest.clock.firstAudioHostTime, 'audio origin', uint64Max)
  if ((frames > 0n) !== (firstAudio !== null)) throw new Error('Captured frame total disagrees with audio origin')
  if (!asset.midiTime || Object.keys(asset.midiTime).length !== 2) throw new Error('Invalid captured MIDI time bounds')
  const first = asset.midiTime.first === null ? null : unsigned(asset.midiTime.first, 'first MIDI time', uint64Max)
  const last = asset.midiTime.last === null ? null : unsigned(asset.midiTime.last, 'last MIDI time', uint64Max)
  if ((first === null) !== (last === null) || first !== null && first > last
      || (unsigned(manifest.midiPacketCount, 'MIDI packet total', uint64Max) > 0n) !== (first !== null)) throw new Error('Captured MIDI time bounds disagree with packet total')
  if (firstAudio !== null && firstAudio < origin) origin = firstAudio
  if (first !== null && first < origin) origin = first
  const audioStart = firstAudio === null ? 0n : firstAudio - origin
  // Include the final packet in a half-open source interval, even when it is at
  // the exact WAV endpoint. The extra tick is a bound, not a fabricated event.
  const midiEnd = last === null ? 0n : last - origin + 1n
  const audioEnd = audioStart + ceil(frames * 1_000_000_000n * clock.denom, clock.rate * clock.numer)
  let extent = audioEnd > midiEnd ? audioEnd : midiEnd
  if (manifest.umpSourceSpan !== undefined) {
    const span = manifest.umpSourceSpan
    if (!span || Object.keys(span).length !== 2 || unsigned(span.origin, 'derived source origin', uint64Max) !== origin
        || unsigned(span.extent, 'derived source extent') < extent) throw new Error('Derived UMP source span disagrees with its data')
    extent = BigInt(span.extent)
  }
  // Keep the recorded/derived source span when messages move inward. An
  // additional authored layer may extend either edge, including after export
  // has been imported as a new source. Validate the base before applying edits.
  let after = origin + extent
  for (const edit of asset.ump?.timing ?? []) {
    const tick = unsigned(edit.hostTime, 'authored MIDI time', uint64Max)
    if (tick < origin) origin = tick
    if (tick + 1n > after) after = tick + 1n
  }
  return { origin: String(origin), extent: String(after - origin) }
}
export function captureRegionTime(asset, { offset, extent }) {
  const range = captureRange(asset), clock = clockOf(asset.manifest)
  const start = unsigned(offset, 'region offset'), length = unsigned(extent, 'region extent'), end = start + length
  if (length === 0n || end > BigInt(range.extent)) throw new Error('Captured region exceeds its source clock span or is empty')
  const divisor = clock.denom * 1_000_000_000n
  const sourceStartSeconds = seconds(start * clock.numer, divisor), sourceEndSeconds = seconds(end * clock.numer, divisor)
  const durationSeconds = seconds(length * clock.numer, divisor)
  if (durationSeconds <= 0 || sourceEndSeconds <= sourceStartSeconds) throw new Error('Captured region time is not representable')
  const frames = BigInt(asset.manifest.audioFrames), audioHost = asset.manifest.clock.firstAudioHostTime
  let audio = null
  if (frames > 0n) {
    const audioStart = BigInt(audioHost) - BigInt(range.origin), frameDivisor = 1_000_000_000n * clock.denom
    const clamp = value => value < 0n ? 0n : value > frames ? frames : value
    const first = clamp(ceil((start - audioStart) * clock.rate * clock.numer, frameDivisor))
    const after = clamp(floor((end - audioStart) * clock.rate * clock.numer, frameDivisor))
    if (after > first) audio = { offsetFrames: String(first), frameCount: String(after - first),
      // Difference in the integer/rational domain before converting to seconds.
      startSeconds: seconds((audioStart - start) * clock.numer * clock.rate + first * frameDivisor, divisor * clock.rate) }
  }
  return { sourceStartSeconds, sourceEndSeconds, durationSeconds, sourceClock: { origin: range.origin, offset, extent,
    numer: asset.manifest.clock.numer, denom: asset.manifest.clock.denom }, audio }
}

// Terminal decimal seconds are parsed as rationals. Round the requested window
// inward to host ticks; conversion never depends on floating-point seconds.
export function captureRegionFromSeconds(asset, startText, durationText) {
  const decimal = text => {
    if (typeof text !== 'string') throw new Error('Choose nonnegative decimal source seconds')
    const match = /^(\d+)(?:\.(\d+))?$/.exec(text.startsWith('.') ? `0${text}` : text)
    if (!match) throw new Error('Choose nonnegative decimal source seconds')
    const denominator = 10n ** BigInt(match[2]?.length ?? 0)
    return [BigInt(match[1]) * denominator + BigInt(match[2] ?? '0'), denominator]
  }
  const [start, sd] = decimal(startText), [length, ld] = decimal(durationText), clock = clockOf(asset.manifest)
  const multiplier = 1_000_000_000n * clock.denom
  const first = ceil(start * multiplier, sd * clock.numer)
  const after = floor((start * ld + length * sd) * multiplier, sd * ld * clock.numer)
  const range = { offset: String(first), extent: String(after - first) }
  captureRegionTime(asset, range)
  return range
}
