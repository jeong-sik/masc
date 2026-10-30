import { captureRegionTime } from './capture-time.mjs'
import { validateCalibrationProfile, calibrationResidual } from './calibration-profile.mjs'
import { gcd, fraction, projectNanoseconds, exactSeconds } from './exact-time.mjs'

export function validateClockOffset(value) {
  if (!value || Object.keys(value).length !== 2 || typeof value.numerator !== 'string' || !/^(0|-?[1-9][0-9]*)$/.test(value.numerator)
      || typeof value.denominator !== 'string' || !/^[1-9][0-9]*$/.test(value.denominator)
      || gcd(BigInt(value.numerator), BigInt(value.denominator)) !== 1n) throw new Error('Invalid captured clock placement offset')
  return value
}
export function validateCapturePlacement(value) {
  if (!['manual', 'calibrated'].includes(value?.kind) || Object.keys(value).length !== (value.kind === 'manual' ? 2 : 4) || !value.advanceNanoseconds
      || Object.keys(value.advanceNanoseconds).length !== 2) throw new Error('Unknown captured placement correction')
  const { numerator, denominator } = value.advanceNanoseconds
  if (typeof numerator !== 'string' || !/^(0|-?[1-9][0-9]*)$/.test(numerator)
      || typeof denominator !== 'string' || !/^[1-9][0-9]*$/.test(denominator)
      || gcd(BigInt(numerator), BigInt(denominator)) !== 1n) throw new Error('Invalid canonical captured placement fraction')
  if (value.kind === 'calibrated') {
    validateCalibrationProfile(value.profile)
    if (!Number.isSafeInteger(value.match) || !value.profile.pulses[value.match]) throw new Error('Choose one inspected calibration pulse')
    const measured = calibrationResidual(value.profile, value.profile.pulses[value.match])
    if (measured.numerator !== numerator || measured.denominator !== denominator) throw new Error('Calibrated placement disagrees with its selected measured pulse')
  }
  return value
}
export function manualCapturePlacement(milliseconds) {
  if (typeof milliseconds !== 'string' || !/^-?(?:\d+(?:\.\d+)?|\.\d+)$/.test(milliseconds)) throw new Error('Choose signed decimal milliseconds; positive advances, negative delays')
  const negative = milliseconds.startsWith('-'), [whole, digits = ''] = (negative ? milliseconds.slice(1) : milliseconds).split('.')
  return { kind: 'manual', advanceNanoseconds: fraction((BigInt(whole || '0') * 10n ** BigInt(digits.length) + BigInt(digits || '0')) * (negative ? -1n : 1n) * 1_000_000n, 10n ** BigInt(digits.length)) }
}
function startNanoseconds(project, clip) {
  const [baseN, baseD] = projectNanoseconds(project, clip.position)
  const shift = clip.placement ? validateCapturePlacement(clip.placement).advanceNanoseconds : { numerator: '0', denominator: '1' }
  const offset = clip.clockOffsetNanoseconds ? validateClockOffset(clip.clockOffsetNanoseconds) : { numerator: '0', denominator: '1' }
  const shiftD = BigInt(shift.denominator), offsetD = BigInt(offset.denominator)
  return [(baseN * shiftD - BigInt(shift.numerator) * baseD) * offsetD + BigInt(offset.numerator) * baseD * shiftD,
    baseD * shiftD * offsetD]
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
export function capturePlacementStart(project, clip) { return exactSeconds(...startNanoseconds(project, clip)) }

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
    const startSeconds = exactSeconds(BigInt(startNanoseconds.numerator), BigInt(startNanoseconds.denominator))
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
