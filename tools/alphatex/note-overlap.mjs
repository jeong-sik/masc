const overlaps = (a, b) => a.duration === 0
  ? b.duration === 0 ? a.start === b.start : b.start <= a.start && a.start < b.start + b.duration
  : b.duration === 0 ? a.start <= b.start && b.start < a.start + a.duration
    : a.start < b.start + b.duration && b.start < a.start + a.duration

// New-order attacks carry their original event rank. A range's extrema tell
// whether every enclosed attack was also inside the original on/off interval.
function attackIndex(attacks) {
  const size = attacks.length, low = new Array(size * 2), high = new Array(size * 2)
  for (let i = 0; i < size; i++) low[size + i] = high[size + i] = attacks[i].previous
  for (let i = size - 1; i > 0; i--) {
    low[i] = Math.min(low[i * 2], low[i * 2 + 1])
    high[i] = Math.max(high[i * 2], high[i * 2 + 1])
  }
  const bound = rank => {
    let left = 0, right = size
    while (left < right) {
      const middle = Math.floor((left + right) / 2)
      if (attacks[middle].rank < rank) left = middle + 1
      else right = middle
    }
    return left
  }
  return (on, off, previousOn, previousOff) => {
    let left = bound(on + 1) + size, right = bound(off) + size
    const outside = index => low[index] <= previousOn || high[index] >= previousOff
    while (left < right) {
      if (left % 2 && outside(left++)) return true
      if (right % 2 && outside(--right)) return true
      left = Math.floor(left / 2); right = Math.floor(right / 2)
    }
    return false
  }
}

// Tick intervals alone cannot decide an attack/release boundary shared by
// tracks. The actual source sweep is ordered by tick, track and event order.
// Compare every actual attack's relation to the same paired on/off IDs;
// a previously diagnosed attack may still newly enter a different note.
export function assertMidiTimingOrder(before, after) {
  const overlaps = new Set(before.diagnostics.filter(value => value.kind === 'overlapping-key').map(value => value.event))
  const refuse = () => { throw new Error('Edit creates overlapping notes of the same pitch, channel and port') }
  if (after.diagnostics.some(value => value.kind === 'overlapping-key' && !overlaps.has(value.event))) refuse()
  const ranks = performance => new Map(performance.events.map((event,index) => [event.id,index]))
  const oldRanks = ranks(before), newRanks = ranks(after)
  const notes = new Map(after.notes.map(note => [note.id,note])), attacks = new Map()
  const route = note => JSON.stringify([note.port,note.channel,note.pitch])
  for (const [rank, event] of after.events.entries()) {
    if (event.kind !== 'channel' || (event.bytes[0]&0xf0) !== 0x90 || event.bytes[2] === 0) continue
    const key = route({port:event.port,channel:event.bytes[0]&15,pitch:event.bytes[1]})
    if (!attacks.has(key)) attacks.set(key,[])
    attacks.get(key).push({rank,previous:oldRanks.get(event.id)})
  }
  const indexes = new Map([...attacks].map(([key,events]) => [key,attackIndex(events)]))
  for (const original of before.notes) {
    const changed = notes.get(original.id)
    if (!changed) continue
    if (indexes.get(route(original))?.(newRanks.get(changed.id),newRanks.get(changed.off),
      oldRanks.get(original.id),oldRanks.get(original.off))) refuse()
  }
}

// Changes affect existing note starts/durations only. Preserve pre-existing
// same-key overlaps, including point evidence, while refusing each new pair.
export function assertNoNewNoteOverlaps(originals, changes) {
  const edits = new Map(changes.map(change => [change.id,change])), groups = new Map()
  for (const original of originals) {
    const key = JSON.stringify([original.port,original.channel,original.pitch]), edit = edits.get(original.id)
    if (!groups.has(key)) groups.set(key,[])
    groups.get(key).push({original,changed:{...original,start:edit?.start??original.start,duration:edit?.duration??original.duration}})
  }
  for (const group of groups.values()) {
    if (!group.some(row => edits.has(row.original.id))) continue
    group.sort((a,b) => a.changed.start-b.changed.start)
    for (let i=0;i<group.length;i++) {
      const a=group[i]
      for (let j=i+1;j<group.length;j++) {
        const b=group[j]
        if (b.changed.start>a.changed.start+a.changed.duration) break
        if (overlaps(a.changed,b.changed)&&!overlaps(a.original,b.original)) {
          throw new Error('Edit creates overlapping notes of the same pitch, channel and port')
        }
      }
    }
  }
}
