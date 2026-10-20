import { backingFrameClock } from './phrase-backing.mjs'
import { nominalMidiFrame } from './render-midi-clock.mjs'
import { practiceRange, practiceRegionTime } from './practice-source.mjs'
import { gcd } from './exact-time.mjs'

// Invert the same absolute sample boundaries the backing producer used. The
// source window is nominal clock alignment, not a measured latency correction.
export function practicePasses(asset, backing, pass) {
  const range = practiceRange(asset), meta = asset.metadata, render = meta.renderClock
  const clock = backingFrameClock(backing, render.sampleRate), frames = BigInt(meta.renderedFrames)
  const originFrame = nominalMidiFrame(range.origin, meta.input.clock, render)
  const originN = BigInt(originFrame.numerator), originD = BigInt(originFrame.denominator)
  const firstFrame = originN > 0n ? originN / originD : 0n
  const available = frames > 0n && originN < frames * originD
  const first = available ? clock.cycleAt(firstFrame) : null, last = available ? clock.cycleAt(frames - 1n) : null
  const result = { firstPass: first === null ? null : String(first + 1n), lastPass: last === null ? null : String(last + 1n),
    count: available ? String(last - first + 1n) : '0', renderedFrames: String(frames), sampleRate: render.sampleRate,
    tempo: backing.tempo, ppq: backing.ppq, ticks: backing.ticks }
  if (pass === undefined) return result
  if (typeof pass !== 'string' || !/^[1-9][0-9]*$/.test(pass)) throw new Error('Choose a positive original practice pass number')
  const cycle = BigInt(pass) - 1n
  if (!available || cycle < first || cycle > last) throw new Error('Practice pass is outside the rendered source range')
  const begin = clock.at(cycle * BigInt(backing.ticks)), after = clock.at((cycle + 1n) * BigInt(backing.ticks))
  const d = BigInt(render.sampleRate) * BigInt(render.clock.numer)
  const base = (BigInt(render.anchor.hostTime) - BigInt(range.origin)) * d
  const host = frame => base + (frame - BigInt(render.anchor.frame)) * 1_000_000_000n * BigInt(render.clock.denom)
  const rawStart = host(begin), rawEnd = host(after), horizon = host(frames), bound = BigInt(range.extent) * d
  const start = rawStart < 0n ? 0n : rawStart
  const end = [rawEnd, horizon, bound].reduce((a, b) => a < b ? a : b)
  if (end <= start) throw new Error('Practice pass has no retained source window')
  const length = end - start, factor = gcd(gcd(start, length), d)
  const cut = { offset: String(start / factor), extent: String(length / factor), sourceDivisor: String(d / factor) }
  practiceRegionTime(asset, cut)
  return { ...result, pass, full: start === rawStart && end === rawEnd, cut }
}
