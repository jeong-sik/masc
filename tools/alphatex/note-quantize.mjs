// Exact half-up snap on nonnegative, safe integer native ticks.
export function quantizeTick(tick, grid) {
  if (!Number.isSafeInteger(grid) || grid <= 0) throw new Error('Quantize grid must be a positive whole tick count')
  if (!Number.isSafeInteger(tick) || tick < 0) throw new Error('Invalid quantized note position')
  const value = Number((2n * BigInt(tick) + BigInt(grid)) / (2n * BigInt(grid)) * BigInt(grid))
  if (!Number.isSafeInteger(value)) throw new Error('Invalid quantized note position')
  return value
}

const overlaps = (a, b) => a.duration === 0
  ? b.duration === 0 ? a.start === b.start : b.start <= a.start && a.start < b.start + b.duration
  : b.duration === 0 ? a.start <= b.start && b.start < a.start + a.duration
    : a.start < b.start + b.duration && b.start < a.start + a.duration
// Starts only: callers retain their own note identity, release and routing validators.
export function quantizedStarts(originals, selected, grid) {
  quantizeTick(0, grid)
  const starts = new Map(selected.map(note => [note.id, quantizeTick(note.start, grid)])), groups = new Map()
  for (const original of originals) {
    const key = JSON.stringify([original.port, original.channel, original.pitch])
    if (!groups.has(key)) groups.set(key, [])
    groups.get(key).push({ original, changed: { ...original, start: starts.get(original.id) ?? original.start } })
  }
  for (const group of groups.values()) {
    if (!group.some(row => starts.has(row.original.id))) continue
    group.sort((a, b) => a.changed.start - b.changed.start)
    for (let i = 0; i < group.length; i++) {
      const a = group[i]
      for (let j = i + 1; j < group.length; j++) {
        const b = group[j]
        if (b.changed.start > a.changed.start + a.changed.duration) break
        if (overlaps(a.changed, b.changed) && !overlaps(a.original, b.original)) {
          throw new Error('Quantize creates overlapping notes of the same pitch, channel and port')
        }
      }
    }
  }
  return starts
}
