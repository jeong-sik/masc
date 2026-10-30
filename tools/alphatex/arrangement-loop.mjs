import { fraction, rational, projectNanoseconds, exactSeconds } from './exact-time.mjs'

export function validateLoop(range) {
  if (!range || Object.keys(range).some(key => !['start', 'end'].includes(key))
      || !Number.isSafeInteger(range.start) || range.start < 0 || !Number.isSafeInteger(range.end) || range.end <= range.start) {
    throw new Error('Choose an increasing arrangement loop range in whole project ticks')
  }
  return range
}
export function arrangementLoop(project) {
  if (project.playbackLoop === undefined) return null
  const range = validateLoop(project.playbackLoop)
  const start = range.start / project.ppq * 60 / project.tempo, end = range.end / project.ppq * 60 / project.tempo
  if (![start, end].every(Number.isFinite) || end <= start || end * 1e9 >= 2 ** 64) throw new Error('Arrangement loop exceeds the native clock precision or range')
  // The native loop clock measures a tick span. Subtracting rounded absolute
  // seconds changes the period when the same window moves along the timeline.
  const duration = (range.end - range.start) / project.ppq * 60 / project.tempo
  return { start, end, duration,
    startNanoseconds: fraction(...projectNanoseconds(project, range.start)), endNanoseconds: fraction(...projectNanoseconds(project, range.end)) }
}
const subtract = ([a, b], [c, d]) => [a * d - c * b, b * d]
const compare = ([a, b], [c, d]) => a * d < c * b ? -1 : a * d > c * b ? 1 : 0
const later = (a, b) => compare(a, b) >= 0 ? a : b, earlier = (a, b) => compare(a, b) <= 0 ? a : b
const minimum = (a, b) => a < b ? a : b
// Intersect finite source repeats with one loop window on the exact region
// grid. At most a leading partial copy, a compressed block of whole copies and
// a trailing copy remain. Their exact edges abut, so native ownership and
// hand-over need no adjustment. Original source timelines are retained.
export function loopMidiRegions(regions, range) {
  if (!range) return regions
  const origin = rational(range.startNanoseconds), limit = rational(range.endNanoseconds), pieces = []
  for (const region of regions) {
    const [startN, startD] = rational(region.startNanoseconds), [periodN, periodD] = rational(region.periodNanoseconds)
    const count = BigInt(region.repeatCount), edge = copy => [startN * periodD + copy * periodN * startD, startD * periodD]
    const from = later(origin, [startN, startD]), to = earlier(limit, edge(count))
    if (compare(to, from) <= 0) continue
    const [phaseN, phaseD] = subtract(from, [startN, startD])
    let copy = minimum(count - 1n, phaseN * periodD / (phaseD * periodN))
    const sourceAt = (at, copy) => region.sourceStart + exactSeconds(...subtract(at, edge(copy)))
    const add = (label, start, stop, sourceStart, sourceEnd, repeatCount) => {
      if (!(sourceStart >= region.sourceStart && sourceEnd <= region.sourceEnd && sourceEnd > sourceStart)) throw new Error('Loop trim is not representable at source precision')
      const [offsetN, offsetD] = subtract(start, origin), [spanN, spanD] = subtract(stop, start)
      const startNanoseconds = fraction(offsetN, offsetD)
      pieces.push({ ...region, id: JSON.stringify([region.id, label]), startSeconds: exactSeconds(...rational(startNanoseconds)),
        sourceStart, sourceEnd, repeatCount: Number(repeatCount), startNanoseconds, periodNanoseconds: fraction(spanN, spanD * repeatCount) })
    }
    if (compare(from, edge(copy)) > 0) {
      const stop = earlier(to, edge(copy + 1n))
      add('leading', from, stop, sourceAt(from, copy), compare(stop, edge(copy + 1n)) === 0 ? region.sourceEnd : sourceAt(stop, copy), 1n)
      if (compare(stop, to) === 0) continue
      copy++
    }
    const [restN, restD] = subtract(to, edge(copy)), whole = minimum(count - copy, restN * periodD / (restD * periodN))
    if (whole > 0n) { add('whole', edge(copy), edge(copy + whole), region.sourceStart, region.sourceEnd, whole); copy += whole }
    if (compare(edge(copy), to) < 0) add('trailing', edge(copy), to, region.sourceStart, sourceAt(to, copy), 1n)
  }
  if (!pieces.length) throw new Error('Loop range has no audible MIDI regions')
  return pieces
}
