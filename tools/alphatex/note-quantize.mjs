import {assertNoNewNoteOverlaps} from './note-overlap.mjs'
// Exact half-up snap on nonnegative, safe integer native ticks.
export function quantizeTick(tick, grid) {
  if (!Number.isSafeInteger(grid) || grid <= 0) throw new Error('Quantize grid must be a positive whole tick count')
  if (!Number.isSafeInteger(tick) || tick < 0) throw new Error('Invalid quantized note position')
  const value = Number((2n * BigInt(tick) + BigInt(grid)) / (2n * BigInt(grid)) * BigInt(grid))
  if (!Number.isSafeInteger(value)) throw new Error('Invalid quantized note position')
  return value
}

// Starts only: callers retain their own note identity, release and routing validators.
export function quantizedStarts(originals, selected, grid) {
  quantizeTick(0, grid)
  const starts = new Map(selected.map(note => [note.id, quantizeTick(note.start, grid)]))
  assertNoNewNoteOverlaps(originals,selected.map(note => ({id:note.id,start:starts.get(note.id)})))
  return starts
}
