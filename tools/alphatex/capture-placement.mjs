import { captureRegionTime } from './capture-time.mjs'

function gcd(a, b) { a = a < 0n ? -a : a; while (b) [a, b] = [b, a % b]; return a }
function fraction(n, d) { const factor = gcd(n, d); return { numerator: String(n / factor), denominator: String(d / factor) } }
export function validateCapturePlacement(value) {
  if (value?.kind !== 'manual' || Object.keys(value).length !== 2 || !value.advanceNanoseconds
      || Object.keys(value.advanceNanoseconds).length !== 2) throw new Error('Unknown captured placement correction')
  const { numerator, denominator } = value.advanceNanoseconds
  if (typeof numerator !== 'string' || !/^(0|-?[1-9][0-9]*)$/.test(numerator)
      || typeof denominator !== 'string' || !/^[1-9][0-9]*$/.test(denominator)
      || gcd(BigInt(numerator), BigInt(denominator)) !== 1n) throw new Error('Invalid canonical captured placement fraction')
  return value
}
export function manualCapturePlacement(milliseconds) {
  if (typeof milliseconds !== 'string' || !/^-?(?:\d+(?:\.\d+)?|\.\d+)$/.test(milliseconds)) throw new Error('Choose signed decimal milliseconds; positive advances, negative delays')
  const negative = milliseconds.startsWith('-'), [whole, digits = ''] = (negative ? milliseconds.slice(1) : milliseconds).split('.')
  return { kind: 'manual', advanceNanoseconds: fraction((BigInt(whole || '0') * 10n ** BigInt(digits.length) + BigInt(digits || '0')) * (negative ? -1n : 1n) * 1_000_000n, 10n ** BigInt(digits.length)) }
}
function binary(value) {
  if (!Number.isFinite(value) || value <= 0) throw new Error('Invalid placement tempo')
  const view = new DataView(new ArrayBuffer(8)); view.setFloat64(0, value)
  const bits = view.getBigUint64(0), exponent = Number(bits >> 52n & 2047n)
  const mantissa = (bits & ((1n << 52n) - 1n)) + (exponent ? 1n << 52n : 0n), shift = exponent ? exponent - 1075 : -1074
  return shift >= 0 ? [mantissa << BigInt(shift), 1n] : [mantissa, 1n << BigInt(-shift)]
}
function startNanoseconds(project, clip) {
  const [tempoN, tempoD] = binary(project.tempo), baseN = BigInt(clip.position) * 60n * 1_000_000_000n * tempoD, baseD = BigInt(project.ppq) * tempoN
  const shift = clip.placement ? validateCapturePlacement(clip.placement).advanceNanoseconds : { numerator: '0', denominator: '1' }
  const shiftD = BigInt(shift.denominator)
  return [baseN * shiftD - BigInt(shift.numerator) * baseD, baseD * shiftD]
}
function seconds(n, d) {
  d *= 1_000_000_000n
  const result = Number(n / d) + Number(n % d) / Number(d)
  if (!Number.isFinite(result)) throw new Error('Captured placement time is not representable')
  return result
}
function deadlineSeconds(n, d) {
  const ns = n / d + (n % d === 0n ? 0n : 1n)
  let result = Number(ns) / 1e9
  if (!Number.isFinite(result)) throw new Error('Captured placement deadline is not representable')
  // The display conversion must cover the exact native ceil deadline, even
  // when binary64 multiplication would otherwise lose its last nanosecond.
  const view = new DataView(new ArrayBuffer(8))
  while (BigInt(Math.ceil(result * 1e9)) < ns) {
    view.setFloat64(0, result); view.setBigUint64(0, view.getBigUint64(0) + 1n); result = view.getFloat64(0)
  }
  return result
}
export function capturePlacementStart(project, clip) { return seconds(...startNanoseconds(project, clip)) }

// Keep editor/document identities and source cuts unchanged. Only the prepared
// transport can project a cropped first copy plus a compressed remaining tail.
export function projectCapturedPlacement(project, asset, clip) {
  const [startN, startD] = startNanoseconds(project, clip), { numer, denom } = asset.manifest.clock
  const n = BigInt(numer), d = BigInt(denom), length = BigInt(clip.extent), count = BigInt(clip.repeat)
  const emit = (offset, extent, repeat, delta) => {
    const source = captureRegionTime(asset, { offset: String(offset), extent: String(extent) })
    const absoluteN = startN * d + delta * n * startD, absoluteD = startD * d
    // Native re-derives the display from the reduced fraction and requires equality.
    const startNanoseconds = fraction(absoluteN, absoluteD)
    const startSeconds = seconds(BigInt(startNanoseconds.numerator), BigInt(startNanoseconds.denominator))
    return { ...clip, offset: String(offset), extent: String(extent), repeat: Number(repeat), ...source, startSeconds, startNanoseconds,
      endSeconds: deadlineSeconds(absoluteN + extent * repeat * n * startD, absoluteD) }
  }
  const offset = BigInt(clip.offset)
  if (startN >= 0n) return [emit(offset, length, count, 0n)]
  const cutN = -startN * d, cutD = startD * n
  const skipped = cutN / (cutD * length), phaseN = cutN % (cutD * length)
  if (skipped >= count) return []
  if (phaseN === 0n) return [emit(offset, length, count - skipped, skipped * length)]
  const phase = phaseN / cutD + (phaseN % cutD > 0n ? 1n : 0n), result = []
  if (phase < length) result.push(emit(offset + phase, length - phase, 1n, skipped * length + phase))
  if (skipped + 1n < count) result.push(emit(offset, length, count - skipped - 1n, (skipped + 1n) * length))
  return result
}
