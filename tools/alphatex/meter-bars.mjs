// Bars and beats from a time-signature map. Each signature starts a new bar
// at its own tick, where an SMF time-signature event takes effect. Ticks are
// integers; positions are compared in integer tick*denominator units, so an
// uneven bar length never rounds a bar line away.

const defaultMeter = { tick: 0, numerator: 4, denominator: 4 }

// [{ tick, numerator, denominator }] in ascending tick order. Before the first
// signature the SMF default 4/4 applies.
export function meterSegments(meters) {
  const segments = meters.length && meters[0].tick === 0 ? [] : [defaultMeter]
  for (const { tick, numerator, denominator } of meters) {
    if (!Number.isInteger(tick) || tick < 0 || !Number.isInteger(numerator) || numerator <= 0
      || !Number.isInteger(denominator) || denominator <= 0) throw new Error('Invalid time signature')
    if (segments.length && tick < segments.at(-1).tick) throw new Error('Time signatures must be in tick order')
    if (segments.length && segments.at(-1).tick === tick) segments.pop()
    segments.push({ tick, numerator, denominator })
  }
  return segments
}

// 1-based bar and beat of a tick; beat may be fractional within its bar.
export function barAt(tick, segments, per) {
  let bars = 0
  for (const [index, segment] of segments.entries()) {
    const next = segments[index + 1]?.tick ?? Infinity
    const scaledBar = segment.numerator * per * 4
    if (tick < next) {
      const offset = (tick - segment.tick) * segment.denominator
      const bar = Math.floor(offset / scaledBar)
      return { bar: bars + bar + 1, beat: (offset - bar * scaledBar) / (per * 4) + 1 }
    }
    bars += Math.ceil((next - segment.tick) * segment.denominator / scaledBar)
  }
  throw new Error('Tick before the first time signature')
}

export function isBarStart(tick, segments, per) {
  const segment = segments.findLast(value => value.tick <= tick)
  return segment !== undefined && (tick - segment.tick) * segment.denominator % (segment.numerator * per * 4) === 0
}

export const beatText = beat => Number.isInteger(beat) ? String(beat) : beat.toFixed(2)

// The bar holding a tick, as integer ticks: [start, end). A later signature
// ends a bar early. A bar line between ticks is refused rather than rounded.
export function barSpan(tick, segments, per) {
  const index = segments.findLastIndex(value => value.tick <= tick)
  if (index < 0) throw new Error('Tick before the first time signature')
  const segment = segments[index], scaledBar = segment.numerator * per * 4
  const bar = Math.floor((tick - segment.tick) * segment.denominator / scaledBar)
  const start = segment.tick + bar * scaledBar / segment.denominator
  const end = Math.min(segments[index + 1]?.tick ?? Infinity, segment.tick + (bar + 1) * scaledBar / segment.denominator)
  if (!Number.isInteger(start) || !Number.isInteger(end)) throw new Error('This bar line falls between MIDI ticks')
  return { start, end }
}
