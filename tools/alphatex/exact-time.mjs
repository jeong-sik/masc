// Exact nanosecond time as BigInt [numerator, denominator] pairs. Native plans
// receive them as canonical decimal fractions (ExactNanoseconds in MidiTransport.swift).
export function gcd(a, b) { a = a < 0n ? -a : a; while (b) [a, b] = [b, a % b]; return a }
export function fraction(n, d) { const factor = gcd(n, d); return { numerator: String(n / factor), denominator: String(d / factor) } }
export function rational(value) { return [BigInt(value.numerator), BigInt(value.denominator)] }
// A binary64 tempo is itself an exact dyadic rational.
export function binary(value) {
  if (!Number.isFinite(value) || value <= 0) throw new Error('Invalid exact tempo')
  const view = new DataView(new ArrayBuffer(8)); view.setFloat64(0, value)
  const bits = view.getBigUint64(0), exponent = Number(bits >> 52n & 2047n)
  const mantissa = (bits & ((1n << 52n) - 1n)) + (exponent ? 1n << 52n : 0n), shift = exponent ? exponent - 1075 : -1074
  return shift >= 0 ? [mantissa << BigInt(shift), 1n] : [mantissa, 1n << BigInt(-shift)]
}
export function projectNanoseconds(project, position) {
  const [tempoN, tempoD] = binary(project.tempo)
  return [BigInt(position) * 60n * 1_000_000_000n * tempoD, BigInt(project.ppq) * tempoN]
}
// The binary64 display native code compares with an exact start.
export function exactSeconds(n, d) {
  d *= 1_000_000_000n
  const result = Number(n / d) + Number(n % d) / Number(d)
  if (!Number.isFinite(result)) throw new Error('Exact time is not representable')
  return result
}
// MidiRegion.boundary(copy): start + copy * period, rounded up once to whole
// nanoseconds and divided by 1e9 in binary64.
export function regionEdgeSeconds(start, period, copy) {
  const [sn, sd] = rational(start), [pn, pd] = rational(period)
  const n = sn * pd + BigInt(copy) * pn * sd, d = sd * pd
  return Number(n / d + (n % d ? 1n : 0n)) / 1e9
}
