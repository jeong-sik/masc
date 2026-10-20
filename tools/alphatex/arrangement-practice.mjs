import { readFile, writeFile, rm } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { createHash, randomUUID } from 'node:crypto'
import { regionEdgeSeconds } from './exact-time.mjs'

export function validatePractice(value) {
  if (!value || Object.keys(value).some(key => !['countInBars', 'metronome'].includes(key))
    || !Number.isSafeInteger(value.countInBars) || value.countInBars < 0 || typeof value.metronome !== 'boolean') {
    throw new Error('Choose a nonnegative count-in bar count and metronome on or off')
  }
  return value
}
export const practiceEnabled = project => !!project.practice && (project.practice.countInBars > 0 || project.practice.metronome)
const gcd = (a, b) => { while (b) [a, b] = [b, a % b]; return a }

// Keep the tempo's actual binary64 value. Each native beat is rounded from its
// absolute rational position, so neither bars nor a long session accumulate drift.
export function practiceClock(project) {
  const policy = validatePractice(project.practice)
  const tempo = project.tempo, [beatsPerBar, unit] = project.meter
  if (!Number.isFinite(tempo) || tempo <= 0 || ![beatsPerBar, unit].every(n => Number.isSafeInteger(n) && n > 0)) throw new Error('Invalid practice tempo or meter')
  const data = new DataView(new ArrayBuffer(8)); data.setFloat64(0, tempo)
  const bits = data.getBigUint64(0), exponent = Number(bits >> 52n & 2047n)
  let n = (bits & ((1n << 52n) - 1n)) + (exponent ? 1n << 52n : 0n), d = 1n
  const shift = exponent ? exponent - 1075 : -1074
  if (shift >= 0) n <<= BigInt(shift); else d <<= BigInt(-shift)
  let numerator = 240_000_000_000n * d, denominator = n * BigInt(unit)
  const factor = gcd(numerator, denominator); numerator /= factor; denominator /= factor
  const max = (1n << 128n) - 1n
  if (numerator > max || denominator > max) throw new Error('Practice tempo exceeds the native rational clock range')
  const countInSeconds = Number(numerator * BigInt(policy.countInBars) * BigInt(beatsPerBar)) / Number(denominator) / 1e9
  if (!Number.isFinite(countInSeconds)) throw new Error('Count-in exceeds the native timeline')
  return { period: { numerator: String(numerator), denominator: String(denominator) }, beatsPerBar, countInSeconds }
}
function clickWave() {
  // A 12 ms decaying tone. Bar accents use the same waveform at full gain;
  // other beats use half gain in the native stream, independent of buffer size.
  const rate = 48000, frames = 576, bytes = Buffer.alloc(44 + frames * 2)
  bytes.write('RIFF'); bytes.writeUInt32LE(bytes.length - 8, 4); bytes.write('WAVEfmt ', 8)
  bytes.writeUInt32LE(16, 16); bytes.writeUInt16LE(1, 20); bytes.writeUInt16LE(1, 22)
  bytes.writeUInt32LE(rate, 24); bytes.writeUInt32LE(rate * 2, 28); bytes.writeUInt16LE(2, 32); bytes.writeUInt16LE(16, 34)
  bytes.write('data', 36); bytes.writeUInt32LE(frames * 2, 40)
  for (let i = 0; i < frames; i++) bytes.writeInt16LE(Math.round(12000 * Math.sin(2 * Math.PI * 1800 * i / rate) * (1 - i / frames) ** 2), 44 + 2 * i)
  return { bytes, sampleRate: rate, channels: 1, frames }
}

async function prepareLoopPractice(project, prepared, original, clock, signal) {
  const beats = BigInt(project.practice.countInBars) * BigInt(clock.beatsPerBar)
  let n = BigInt(clock.period.numerator) * beats, d = BigInt(clock.period.denominator)
  const g = gcd(n, d); n /= g; d /= g
  if (n > (1n << 128n) - 1n || d > (1n << 128n) - 1n) throw new Error('Count-in exceeds the native rational clock range')
  const countIn = Number(n) / Number(d) / 1e9
  const loop = { ...project.playbackLoop, ppq: project.ppq, tempo: project.tempo }
  const backing = (loop.end - loop.start) / loop.ppq * 60 / loop.tempo, duration = countIn + backing
  if (!Number.isFinite(duration) || duration <= countIn || countIn * 1e9 >= 2 ** 64
    || Math.abs(duration - countIn - backing) >= 1 / 48000) throw new Error('Count-in loses the arrangement duration')
  const plan = prepared.format === 'midi-arrangement'
    ? { schemaVersion: 2, kind: 'mixed-arrangement', assets: [], regions: [], midi: original }
    : { ...original }
  plan.loop = loop
  plan.practice = { countInSeconds: countIn, duration: backing, loop: { period: clock.period,
    countInBeats: String(beats), beatsPerBar: clock.beatsPerBar, unit: project.meter[1], metronome: project.practice.metronome } }
  plan.duration = duration
  const { bytes, ...metadata } = clickWave(), id = randomUUID(), path = join(dirname(prepared.path), id + '.wav')
  await writeFile(path, bytes, { flag: 'wx', mode: 0o600, signal })
  plan.assets.push({ id, path, sha256: createHash('sha256').update(bytes).digest('hex'), ...metadata })
  const pulse = seconds => ({ id: randomUUID(), asset: id, startSeconds: 0, offsetFrames: 0,
    frameCount: metadata.frames, repeat: 1, pulseClock: { period: clock.period, beatsPerBar: clock.beatsPerBar, duration: seconds } })
  if (countIn > 0) {
    const intro = pulse(countIn); intro.pulseClock.beatCount = String(beats); plan.regions.push(intro)
  }
  if (project.practice.metronome) plan.regions.push({ ...pulse(backing), pulseLoopUnit: project.meter[1] })
  signal?.throwIfAborted()
  await writeFile(prepared.path, JSON.stringify(plan), { mode: 0o600, signal })
  signal?.throwIfAborted()
  return { ...prepared, duration: backing, format: plan.kind }
}

// Extend the already snapshotted plan, never its sources. Only region placement
// moves: SMF bytes, UMP host timestamps, capture cuts and correction remain exact.
export async function preparePractice(project, prepared, { signal } = {}) {
  if (!practiceEnabled(project)) return prepared
  try {
    signal?.throwIfAborted()
    const clock = practiceClock(project), original = JSON.parse(await readFile(prepared.path, { encoding: 'utf8', signal }))
    if (project.playbackLoop !== undefined) return await prepareLoopPractice(project, prepared, original, clock, signal)
    const countIn = clock.countInSeconds
    let duration = original.duration + countIn
    if (!Number.isFinite(duration) || duration <= countIn || Math.abs(duration - countIn - original.duration) >= 1 / (original.assets ?? []).reduce((rate, asset) => Math.max(rate, asset.sampleRate), 48000)) throw new Error('Count-in loses the arrangement duration')
    const shiftRegion = region => {
      if (!region.startNanoseconds) return { ...region, startSeconds: region.startSeconds + countIn }
      const original = region.startNanoseconds, d = BigInt(original.denominator), n = BigInt(original.numerator)
      const cn = BigInt(clock.period.numerator) * BigInt(project.practice.countInBars) * BigInt(clock.beatsPerBar)
      const cd = BigInt(clock.period.denominator)
      let numerator = n * cd + cn * d, denominator = d * cd
      const factor = gcd(numerator, denominator); numerator /= factor; denominator /= factor
      if (numerator > (1n << 128n) - 1n || denominator * 1_000_000_000n > (1n << 128n) - 1n) throw new Error('Practice placement exceeds the native rational clock range')
      const secondsDenom = denominator * 1_000_000_000n
      const startSeconds = Number(numerator / secondsDenom) + Number(numerator % secondsDenom) / Number(secondsDenom)
      return { ...region, startSeconds, startNanoseconds: { numerator: String(numerator), denominator: String(denominator) } }
    }
    const shift = timeline => ({ ...timeline, duration, regions: timeline.regions.map(shiftRegion) })
    const plan = prepared.format === 'midi-arrangement'
      ? { schemaVersion: 2, kind: 'mixed-arrangement', assets: [], regions: [], midi: shift(original) }
      : { ...original, regions: original.regions.map(region => ({ ...region, startSeconds: region.startSeconds + countIn })),
        ...(original.midi ? { midi: shift(original.midi) } : {}), ...(original.umpRegions ? { umpRegions: shift(original.umpRegions) } : {}) }
    if (plan.midi) {
      // Native SMF admission reads each shifted region's exact last edge.
      duration = plan.midi.regions.reduce((end, region) => Math.max(end,
        regionEdgeSeconds(region.startNanoseconds, region.periodNanoseconds, region.repeatCount)), duration)
      plan.midi.duration = duration
    }
    if (plan.umpRegions) for (const region of plan.regions) {
      const paired = plan.umpRegions.regions.find(notes => notes.id === region.id && notes.component === undefined)
      if (paired?.startNanoseconds) region.startSeconds = paired.startSeconds
    }
    if (plan.umpRegions) {
      // Native UMP admission rounds an exact exclusive end outward to whole
      // nanoseconds. A nearest Double sum can be one nanosecond too short.
      let after = BigInt(Math.ceil(duration * 1e9))
      for (const region of plan.umpRegions.regions) {
        const source = plan.umpRegions.sources.find(source => source.id === region.source)
        const clock = source.timeline.clock
        const start = region.startNanoseconds ?? { numerator: String(Math.floor(region.startSeconds * 1e9)), denominator: '1' }
        const d = BigInt(start.denominator) * BigInt(clock.denom)
        const n = BigInt(start.numerator) * BigInt(clock.denom)
          + BigInt(region.extent) * BigInt(region.repeatCount) * BigInt(clock.numer) * BigInt(start.denominator)
        const end = n / d + (n % d ? 1n : 0n)
        if (end > after) after = end
      }
      if (after >= 1n << 64n) throw new Error('Practice exceeds the native nanosecond timeline')
      let seconds = Number(after / 1_000_000_000n) + Number(after % 1_000_000_000n) / 1e9
      const bits = new DataView(new ArrayBuffer(8))
      while (BigInt(Math.ceil(seconds * 1e9)) < after) {
        bits.setFloat64(0, seconds); bits.setBigUint64(0, bits.getBigUint64(0) + 1n); seconds = bits.getFloat64(0)
      }
      duration = Math.max(duration, seconds)
      plan.umpRegions.duration = duration
      if (plan.midi) plan.midi.duration = duration
    }
    const { bytes, ...metadata } = clickWave(), id = randomUUID(), path = join(dirname(prepared.path), id + '.wav')
    await writeFile(path, bytes, { flag: 'wx', mode: 0o600, signal })
    plan.assets.push({ id, path, sha256: createHash('sha256').update(bytes).digest('hex'), ...metadata })
    plan.regions.push({ id, asset: id, startSeconds: 0, offsetFrames: 0, frameCount: metadata.frames, repeat: 1,
      pulseClock: { period: clock.period, beatsPerBar: clock.beatsPerBar, duration: project.practice.metronome ? duration : countIn } })
    plan.practice = { countInSeconds: countIn, duration: duration - countIn }
    plan.duration = duration
    signal?.throwIfAborted()
    await writeFile(prepared.path, JSON.stringify(plan), { mode: 0o600, signal })
    signal?.throwIfAborted()
    return { ...prepared, format: plan.kind }
  } catch (error) { await rm(dirname(prepared.path), { recursive: true, force: true }); throw error }
}
