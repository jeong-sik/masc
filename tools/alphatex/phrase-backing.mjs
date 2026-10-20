import { sequenceEvents } from './sequencer-project.mjs'

// Snapshot the musical decision before opening devices. The selected track is
// played live; other audible tracks keep their own channels and controls.
export function phraseBacking(project, trackID, loop = false) {
  if (project?.kind === 'midi-source') throw new Error('Practice backing needs a phrase; original MIDI sources retain their arrangement transport')
  const schedule = sequenceEvents(project, { loop })
  const selected = project.tracks.find(track => track.id === trackID)
  if (!selected) throw new Error('Select a phrase track before practice input')
  const bytes = event => {
    switch (event.kind) {
      case 'control': return [0xb0 | event.channel, event.controller, event.value]
      case 'on': return [0x90 | event.channel, event.pitch, event.velocity]
      case 'off': return [0x80 | event.channel, event.pitch, event.velocity]
      default: throw new Error('Unsupported phrase backing event')
    }
  }
  const events = schedule.events.filter(event => event.track !== trackID && event.kind !== 'program')
  const held = new Map()
  let minimumNoteTicks = null
  for (const event of events) {
    if (event.kind === 'control') continue
    const key = event.channel * 128 + event.pitch
    if (event.kind === 'on') held.set(key, event.tick)
    if (event.kind === 'off') {
      const duration = event.tick - held.get(key)
      minimumNoteTicks = minimumNoteTicks === null ? duration : Math.min(minimumNoteTicks, duration)
      held.delete(key)
    }
  }
  return { kind: 'phrase-backing', ppq: project.ppq, tempo: project.tempo, ticks: schedule.ticks, minimumNoteTicks,
    track: selected.id, channel: selected.channel,
    channels: [...new Set(events.filter(event => event.kind === 'on').map(event => event.channel))],
    initial: [[0xb0 | selected.channel, 7, selected.level], [0xb0 | selected.channel, 10, selected.pan]],
    events: events.map(event => ({ tick: event.tick, bytes: bytes(event) })) }
}

// Device blocks consume this cursor. Round absolute musical positions once,
// rather than adding a rounded cycle length (which would drift each repeat).
export function backingClock(plan, sampleRate) {
  if (plan?.kind !== 'phrase-backing' || !Number.isSafeInteger(sampleRate) || sampleRate <= 0
      || !Number.isSafeInteger(plan.ticks) || plan.ticks <= 0
      || !Number.isSafeInteger(plan.ppq) || plan.ppq <= 0
      || !Number.isSafeInteger(plan.tempo) || plan.tempo <= 0) throw new Error('Invalid phrase backing clock')
  const n = 60n * BigInt(sampleRate), d = BigInt(plan.ppq) * BigInt(plan.tempo)
  const at = tick => (tick * n * 2n + d) / (2n * d)
  if (BigInt(plan.ticks) * n < d) throw new Error('Practice cycle is shorter than one output frame')
  if (plan.minimumNoteTicks !== null && BigInt(plan.minimumNoteTicks) * n < d) throw new Error('Practice note is shorter than one output frame')
  let cycle = 0n, index = 0, position = 0n, first = true
  return {
    block(start, count) {
      start = BigInt(start)
      if (start !== position || !Number.isSafeInteger(count) || count <= 0) throw new Error('Discontinuous backing demand')
      const end = start + BigInt(count), messages = []
      if (first) { messages.push(...plan.initial.map(bytes => ({ frame: 0, bytes }))); first = false }
      if (plan.events.length) while (true) {
        const event = plan.events[index], frame = at(cycle * BigInt(plan.ticks) + BigInt(event.tick))
        if (frame >= end) break
        if (frame < start) throw new Error('Backing event precedes its device block')
        messages.push({ frame: Number(frame - start), bytes: event.bytes })
        if (++index === plan.events.length) { index = 0; cycle++ }
      }
      position = end
      return messages
    },
    diagnostics() { return { track: plan.track, channel: plan.channel, cycle: String(cycle), producedFrames: String(position) } },
  }
}
