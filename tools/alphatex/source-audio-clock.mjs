import { tempoEvent } from './midi-source.mjs'

// Exact source seconds. PCM samples are selected inside the half-open MIDI
// trim; their count is independent of the authored copy/repeat interval.
export function sourceAudioClock(performance, offset, extent) {
  if (![offset, extent].every(Number.isSafeInteger) || offset < 0 || extent <= 0
      || !Number.isSafeInteger(offset + extent) || offset + extent > performance.ticks) throw new Error('Invalid source audio trim')
  const timing = performance.timing
  let denominator, at
  if (timing.kind === 'smpte') {
    denominator = BigInt(timing.numerator) * BigInt(timing.ticksPerFrame)
    at = tick => BigInt(tick) * BigInt(timing.denominator)
  } else {
    denominator = BigInt(timing.ppq) * 1_000_000n
    at = tick => {
      let position = 0, micros = 500000, numerator = 0n
      for (const event of performance.events) {
        if (event.tick > tick) break
        if (event.kind !== 'meta' || event.type !== 0x51) continue
        numerator += BigInt(event.tick - position) * BigInt(micros)
        position = event.tick; micros = tempoEvent(event).micros
      }
      return numerator + BigInt(tick - position) * BigInt(micros)
    }
  }
  return { start: String(at(offset)), end: String(at(offset + extent)), denominator: String(denominator) }
}

// Walk the same original clock once for a render stream. Ceil places an event
// at the first sample which is not before its authored time; same-time source
// order is retained. Never accumulate rounded event/copy durations.
export function sourceAudioEventFrames(performance, sampleRate) {
  if (!Number.isSafeInteger(sampleRate) || sampleRate <= 0 || sampleRate > 0xffffffff) throw new Error('Invalid source audio rate')
  const timing = performance.timing, rate = BigInt(sampleRate)
  const denominator = timing.kind === 'ppq' ? BigInt(timing.ppq) * 1_000_000n
    : BigInt(timing.numerator) * BigInt(timing.ticksPerFrame)
  let tick = 0, micros = 500000n, total = 0n
  return performance.events.map(event => {
    total = timing.kind === 'ppq' ? total + BigInt(event.tick - tick) * micros
      : BigInt(event.tick) * BigInt(timing.denominator)
    tick = event.tick
    const scaled = total * rate, frame = scaled / denominator + (scaled % denominator ? 1n : 0n)
    if (frame > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('Source audio exceeds exact plan frame precision')
    const tempo = timing.kind === 'ppq' ? tempoEvent(event) : null
    if (tempo) micros = BigInt(tempo.micros)
    return { event, frame: Number(frame) }
  })
}

export function sourceAudioFrames(clock, sampleRate) {
  if (!Number.isSafeInteger(sampleRate) || sampleRate <= 0 || sampleRate > 0xffffffff) throw new Error('Invalid source audio rate')
  const start = BigInt(clock.start), end = BigInt(clock.end), d = BigInt(clock.denominator), rate = BigInt(sampleRate)
  if (start < 0n || end <= start || d <= 0n) throw new Error('Invalid source audio clock')
  const ceil = n => n / d + (n % d ? 1n : 0n)
  const offset = ceil(start * rate), count = ceil(end * rate) - offset
  if (offset + count > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('Source audio exceeds exact plan frame precision')
  return { offsetFrames: Number(offset), frameCount: Number(count) }
}
