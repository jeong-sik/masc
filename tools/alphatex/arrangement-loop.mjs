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
export function requireLoopTransport(project) {
  if (project.playbackLoop !== undefined) throw new Error('Continuous loop playback for audio, captured UMP and practice clicks is not connected yet; use :loop off for this route')
}

// Intersect finite source repeats with one loop window. At most a leading
// partial copy, a compressed block of whole copies and a trailing copy remain.
// Original source timelines are retained; no musical messages are flattened.
export function loopMidiRegions(regions, range) {
  if (!range) return regions
  const result = []
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
    const add = (label, start, sourceStart, sourceEnd, repeatCount) => {
      if (!(sourceStart >= region.sourceStart && sourceEnd <= region.sourceEnd && sourceEnd > sourceStart)
          || !Number.isSafeInteger(repeatCount) || repeatCount <= 0 || start - range.start < 0
          || start + (sourceEnd - sourceStart) * repeatCount > range.end) throw new Error('Loop trim is not representable at source precision')
      result.push({ ...region, id: JSON.stringify([region.id, label]), startSeconds: start - range.start, sourceStart, sourceEnd, repeatCount })
    }
    if (from > position(copy)) {
      const stop = Math.min(to, position(copy + 1))
      add('leading', from, region.sourceStart + (from - position(copy)), stop === position(copy + 1) ? region.sourceEnd : region.sourceStart + (stop - position(copy)), 1)
      if (stop === to) continue
      copy++
    }
    const start = position(copy)
    let count = Math.min(region.repeatCount - copy, Math.max(0, Math.floor((to - start) / period)))
    if (position(copy + count) > to) count--
    if (copy + count < region.repeatCount && position(copy + count + 1) <= to) count++
    if (count > 0) { add('whole', start, region.sourceStart, region.sourceEnd, count); copy += count }
    if (position(copy) < to) add('trailing', position(copy), region.sourceStart, region.sourceStart + (to - position(copy)), 1)
  }
  if (!result.length) throw new Error('Loop range has no audible MIDI regions')
  return result
}
