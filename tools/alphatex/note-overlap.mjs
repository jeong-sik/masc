const overlaps = (a, b) => a.duration === 0
  ? b.duration === 0 ? a.start === b.start : b.start <= a.start && a.start < b.start + b.duration
  : b.duration === 0 ? a.start <= b.start && b.start < a.start + a.duration
    : a.start < b.start + b.duration && b.start < a.start + a.duration

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
  for (const event of before.events) {
    if (event.kind !== 'channel' || (event.bytes[0]&0xf0) !== 0x90 || event.bytes[2] === 0) continue
    const key = route({port:event.port,channel:event.bytes[0]&15,pitch:event.bytes[1]})
    if (!attacks.has(key)) attacks.set(key,[])
    attacks.get(key).push(event.id)
  }
  const encloses = (positions,note,attack) => positions.get(note.id)<positions.get(attack) && positions.get(attack)<positions.get(note.off)
  for (const original of before.notes) {
    const changed = notes.get(original.id)
    if (!changed) continue
    for (const attack of attacks.get(route(original))??[]) {
      if (encloses(newRanks,changed,attack) && !encloses(oldRanks,original,attack)) refuse()
    }
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
