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
  return { start, end, duration: end - start }
}
// Intersect finite source repeats with one loop window. At most a leading
// partial copy, a compressed block of whole copies and a trailing copy remain.
// Original source timelines are retained; no musical messages are flattened.
export function loopMidiRegions(regions, range) {
  if (!range) return regions
  const pieces = []
  for (const region of regions) {
    const period = region.sourceEnd - region.sourceStart
    const end = region.startSeconds + period * region.repeatCount
    const from = Math.max(range.start, region.startSeconds), to = Math.min(range.end, end)
    if (to <= from) continue
    const position = copy => region.startSeconds + copy * period
    let copy = Math.min(region.repeatCount - 1, Math.max(0, Math.floor((from - region.startSeconds) / period)))
    // Check the computed copy against actual binary64 boundary arithmetic.
    if (position(copy) > from) copy--
    if (copy + 1 < region.repeatCount && position(copy + 1) <= from) copy++
    if (copy < 0 || !(position(copy) <= from && position(copy + 1) > from)) throw new Error('Loop boundary loses source repeat precision')
    const add = (label, start, stop, sourceStart, sourceEnd, repeatCount) => {
      if (!(sourceStart >= region.sourceStart && sourceEnd <= region.sourceEnd && sourceEnd > sourceStart)
          || !Number.isSafeInteger(repeatCount) || repeatCount <= 0 || start < range.start || stop > range.end || stop <= start) throw new Error('Loop trim is not representable at source precision')
      pieces.push({ start, stop, spec: { ...region, id: JSON.stringify([region.id, label]), sourceStart, sourceEnd, repeatCount } })
    }
    if (from > position(copy)) {
      const stop = Math.min(to, position(copy + 1))
      add('leading', from, stop, region.sourceStart + (from - position(copy)), stop === position(copy + 1) ? region.sourceEnd : region.sourceStart + (stop - position(copy)), 1)
      if (stop === to) continue
      copy++
    }
    const start = position(copy)
    let count = Math.min(region.repeatCount - copy, Math.max(0, Math.floor((to - start) / period)))
    if (position(copy + count) > to) count--
    if (copy + count < region.repeatCount && position(copy + count + 1) <= to) count++
    if (count > 0) { add('whole', start, position(copy + count), region.sourceStart, region.sourceEnd, count); copy += count }
    if (position(copy) < to) add('trailing', position(copy), to, region.sourceStart, region.sourceStart + (to - position(copy)), 1)
  }
  if (!pieces.length) throw new Error('Loop range has no audible MIDI regions')
  // Cut membership uses original absolute boundaries. Native playback instead
  // evaluates normalizedStart + span * count, which can round differently.
  // Project every boundary once, after all incoming native ends are known.
  // Shared boundaries stay shared across different original regions/sources;
  // originally disjoint intervals cannot acquire a rounding-induced overlap.
  const starts = new Map(), incoming = new Map(), projected = new Map()
  for (const piece of pieces) {
    if (!starts.has(piece.start)) starts.set(piece.start, [])
    starts.get(piece.start).push(piece)
  }
  let previous = 0
  for (const boundary of [...new Set(pieces.flatMap(piece => [piece.start, piece.stop]))].sort((a, b) => a - b)) {
    const startSeconds = Math.max(boundary - range.start, previous, incoming.get(boundary) ?? 0)
    projected.set(boundary, startSeconds); previous = startSeconds
    for (const piece of starts.get(boundary) ?? []) {
      const end = startSeconds + (piece.spec.sourceEnd - piece.spec.sourceStart) * piece.spec.repeatCount
      if (!Number.isFinite(end) || end <= startSeconds) throw new Error('Loop trim is not representable at native precision')
      incoming.set(piece.stop, Math.max(incoming.get(piece.stop) ?? 0, end))
    }
  }
  return pieces.map(piece => ({ ...piece.spec, startSeconds: projected.get(piece.start) }))
}
