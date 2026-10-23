const overlaps = (a, b) => a.duration === 0
  ? b.duration === 0 ? a.start === b.start : b.start <= a.start && a.start < b.start + b.duration
  : b.duration === 0 ? a.start <= b.start && b.start < a.start + a.duration
    : a.start < b.start + b.duration && b.start < a.start + a.duration

// An unclosed attack has no paired note interval. Its onset is conflict
// evidence, not a guessed performance duration or a note added to the project.
// Callers still validate the actual paired releases and source ports on edit.
export function midiTimingEvidence(performance) {
  const events = new Map(performance.events.map(event => [event.id,event]))
  return [...performance.notes,...performance.diagnostics.filter(value => value.kind === 'unclosed-note').map(value => {
    const event = events.get(value.event)
    return { id:event.id,port:event.port,channel:event.bytes[0]&15,pitch:event.bytes[1],start:event.tick,duration:0 }
  })]
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
