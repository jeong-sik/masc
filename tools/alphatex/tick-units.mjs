function rational(value, invalid) {
  if (!['string', 'number'].includes(typeof value)) invalid()
  const text = String(value), fraction = text.split('/')
  let numerator, denominator
  if (fraction.length === 2 && /^[+-]?[0-9]+$/.test(fraction[0]) && /^[0-9]+$/.test(fraction[1])) {
    numerator = BigInt(fraction[0]); denominator = BigInt(fraction[1])
  } else if (fraction.length === 1) {
    const decimal = /^([+-]?)([0-9]*)(?:\.([0-9]*))?$/.exec(text)
    if (!decimal || !(decimal[2] || decimal[3])) invalid()
    numerator = BigInt((decimal[2] || '0') + (decimal[3] || '')) * (decimal[1] === '-' ? -1n : 1n)
    denominator = 10n ** BigInt((decimal[3] || '').length)
  } else invalid()
  if (denominator === 0n) invalid()
  return { numerator, denominator }
}
function wholeTicks(numerator, denominator, signed, invalid) {
  if (numerator % denominator !== 0n) invalid()
  const result = numerator / denominator, maximum = BigInt(Number.MAX_SAFE_INTEGER)
  if (result > maximum || result < (signed ? -maximum : 0n)) invalid()
  return Number(result)
}
// Convert authored units before binary-float rounding can change their meaning.
export function tickUnits(value, per, { signed = false, label = 'Position' } = {}) {
  const invalid = () => { throw new Error(`${label} must resolve to exact whole source ticks`) }
  if (!Number.isSafeInteger(per) || per <= 0) invalid()
  const { numerator, denominator } = rational(value, invalid)
  return wholeTicks(numerator * BigInt(per), denominator, signed, invalid)
}
// Ratios change tick distances, independently of PPQ beats or SMPTE frames.
// BigInt distances retain native host-clock precision; their caller validates
// the final timestamp range. Number callers keep safe-integer admission.
export function scaleTicks(ticks, factor) {
  const invalid = () => { throw new Error('Stretch requires a positive ratio and exact whole source ticks') }
  if (typeof ticks !== 'bigint' && !Number.isSafeInteger(ticks)) invalid()
  const { numerator, denominator } = rational(factor, invalid)
  if (numerator <= 0n) invalid()
  if (typeof ticks === 'bigint') {
    const scaled = ticks * numerator
    if (scaled % denominator) invalid()
    return scaled / denominator
  }
  return wholeTicks(BigInt(ticks) * numerator, denominator, true, invalid)
}
