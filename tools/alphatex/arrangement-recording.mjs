import { captureRange, captureRegionTime } from './capture-time.mjs'
import { editArrangement, validateArrangement } from './arrangement.mjs'
import { validateLoop } from './arrangement-loop.mjs'
import { validateRecordingCorrection, recordingCorrectionCapture } from './recording-correction.mjs'

// Decode the actual binary64 scheduling value, rather than rounding an absolute
// clock through Number or pretending a decimal rendering is the original value.
function rational(value) {
  if (!Number.isFinite(value) || value < 0) throw new Error('Invalid recording position or tempo')
  const bytes = new DataView(new ArrayBuffer(8)); bytes.setFloat64(0, value)
  const bits = bytes.getBigUint64(0), exponent = Number(bits >> 52n & 2047n)
  const mantissa = (bits & ((1n << 52n) - 1n)) + (exponent ? 1n << 52n : 0n)
  const shift = exponent ? exponent - 1075 : -1074
  return shift >= 0 ? [mantissa << BigInt(shift), 1n] : [mantissa, 1n << BigInt(-shift)]
}
const ceil = (n, d) => n / d + (n % d > 0n ? 1n : 0n)
const floor = (n, d) => n / d - (n % d < 0n ? 1n : 0n)
const uint64 = value => {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value) || BigInt(value) > 0xffffffffffffffffn) throw new Error('Invalid recording epoch')
  return BigInt(value)
}
export function recordingEpoch(event) {
  const clock = event?.clock
  if (event?.kind !== 'playing' || !['mach-host-time', 'mach-nanoseconds'].includes(clock?.kind)) throw new Error('Start arrangement playback before recording')
  uint64(clock.anchor); rational(clock.position); rational(event.duration)
  if (clock.position >= event.duration) throw new Error('Arrangement playback has ended')
  if (clock.kind === 'mach-host-time' && ![clock.numer, clock.denom].every(value => Number.isSafeInteger(value) && value > 0)) throw new Error('Missing playback clock timebase')
  if (event.loop) {
    const cycle = clock.cycle
    if (cycle?.kind === 'project') {
      validateLoop({ start: cycle.start, end: cycle.end })
      if (!Number.isSafeInteger(cycle.ppq) || cycle.ppq <= 0 || !Number.isFinite(cycle.tempo) || cycle.tempo <= 0
          || (cycle.end - cycle.start) / cycle.ppq * 60 / cycle.tempo !== event.duration) throw new Error('Recording cycle differs from playback duration')
    } else if (cycle?.kind !== 'seconds' || cycle.duration !== event.duration) throw new Error('Missing recording cycle clock')
  }
  if (event.end !== undefined) uint64(event.end)
  return { clock: structuredClone(clock), duration: event.duration, ...(event.loop ? { loop: true } : {}), ...(event.end === undefined ? {} : { end: event.end }) }
}

// Inward placement on the document's quarter-note tick lattice. The complete
// take remains an asset; only its placed region loses sub-tick pre-roll/tail.
// Return the measured rounding error as a rational host-tick count for audit.
export function recordedRegion(project, asset, epoch) {
  if (epoch.loop) throw new Error('Choose cycle-aware recording placement')
  const checked = recordingEpoch({ kind: 'playing', loop: false, ...epoch })
  const { clock, duration } = checked, source = asset.manifest.clock
  const range = captureRange(asset), origin = BigInt(range.origin), n = BigInt(source.numer), d = BigInt(source.denom)
  if (clock.kind === 'mach-host-time' && (clock.numer !== source.numer || clock.denom !== source.denom)) throw new Error('Recording and playback timebases disagree')
  // Express the playback anchor in the source clock as a rational, including
  // the nanosecond epoch used by a standalone MIDI arrangement.
  const an = uint64(clock.anchor) * (clock.kind === 'mach-nanoseconds' ? d : 1n)
  const ad = clock.kind === 'mach-nanoseconds' ? n : 1n
  const [pn, pd] = rational(clock.position), [tn, td] = rational(project.tempo)
  const unit = d * 1_000_000_000n
  const startN = pn * unit * ad + (origin * ad - an) * n * pd
  const startD = pd * unit * ad
  const tick = ceil(startN * tn * BigInt(project.ppq), startD * td * 60n)
  const position = Number(tick > 0n ? tick : 0n)
  if (!Number.isSafeInteger(position)) throw new Error('Recorded take exceeds the project tick range')
  // Exact host-domain target corresponding to the first nonnegative project tick.
  const targetN = (BigInt(position) * 60n * td * pd - pn * tn * BigInt(project.ppq)) * unit * ad
    + an * n * tn * BigInt(project.ppq) * pd
  const targetD = tn * BigInt(project.ppq) * pd * n * ad
  const offset = ceil(targetN - origin * targetD, targetD)
  const [endN, endD] = rational(duration)
  const after = floor((an - origin * ad) * n * endD * pd + (endN * pd - pn * endD) * unit * ad,
    ad * n * endD * pd)
  const end = after < BigInt(range.extent) ? after : BigInt(range.extent)
  const clip = { position, offset: String(offset), extent: String(end - offset), repeat: 1 }
  captureRegionTime(asset, clip)
  return { ...clip, alignment: { epoch: checked, sourceOrigin: range.origin,
    roundingHostTicks: { numerator: String((origin + offset) * targetD - targetN), denominator: String(targetD) } } }
}

function gcd(a, b) { a = a < 0n ? -a : a; while (b) [a, b] = [b, a % b]; return a }
function ratio(n, d = 1n) { const g = gcd(n, d); return [n / g, d / g] }
const add = ([a, b], [c, d]) => ratio(a * d + c * b, b * d)
const subtract = ([a, b], [c, d]) => ratio(a * d - c * b, b * d)
const multiply = ([a, b], [c, d]) => ratio(a * c, b * d)
const divide = ([a, b], [c, d]) => ratio(a * d, b * c)
const fraction = ([n, d]) => ({ numerator: String(n), denominator: String(d) })

// Cut only at original integer host ticks. Every retained source tick belongs
// to exactly one pass; its exact fractional project placement survives the
// editor's display tick. The complete WAV/UMP remains one immutable asset.
export function recordedLoopRegions(project, asset, epoch, correction = { kind: 'none' }) {
  const checked = recordingEpoch({ kind: 'playing', ...epoch })
  if (!checked.loop) throw new Error('Loop recording needs a cycle epoch')
  const loop = validateLoop(project.playbackLoop), { clock } = checked, source = asset.manifest.clock
  const cycle = clock.cycle
  if (cycle.kind === 'project' && (cycle.start !== loop.start || cycle.end !== loop.end || cycle.ppq !== project.ppq || cycle.tempo !== project.tempo)) throw new Error('Project changed its recording cycle')
  if (clock.kind === 'mach-host-time' && (clock.numer !== source.numer || clock.denom !== source.denom)) throw new Error('Recording and playback timebases disagree')
  validateRecordingCorrection(correction); recordingCorrectionCapture(correction, asset.manifest)
  const range = captureRange(asset), origin = BigInt(range.origin)
  let extent = BigInt(range.extent)
  const nativeTick = ratio(BigInt(source.numer), BigInt(source.denom))
  const anchor = clock.kind === 'mach-host-time' ? multiply([uint64(clock.anchor), 1n], nativeTick) : [uint64(clock.anchor), 1n]
  if (checked.end !== undefined) {
    const end = clock.kind === 'mach-host-time' ? multiply([uint64(checked.end), 1n], nativeTick) : [uint64(checked.end), 1n]
    const stop = divide(subtract(end, multiply([origin, 1n], nativeTick)), nativeTick)
    const bound = ceil(...stop); if (bound < extent) extent = bound
  }
  const elapsed = subtract(multiply([origin, 1n], nativeTick), anchor)
  const tick = divide([60_000_000_000n, 1n], multiply(rational(project.tempo), [BigInt(project.ppq), 1n]))
  const period = cycle.kind === 'project' ? multiply(tick, [BigInt(loop.end - loop.start), 1n]) : multiply(rational(cycle.duration), [1_000_000_000n, 1n])
  const projectStart = multiply(tick, [BigInt(loop.start), 1n]), phase = multiply(rational(clock.position), [1_000_000_000n, 1n])
  const components = correction.kind === 'none' ? [undefined] : ['midi', 'audio'], regions = []
  for (const component of components) {
    const advance = component === 'audio' ? [BigInt(correction.placement.advanceNanoseconds.numerator), BigInt(correction.placement.advanceNanoseconds.denominator)] : [0n, 1n]
    const start = subtract(elapsed, advance), displacement = add(start, phase)
    const before = divide(subtract([0n, 1n], start), nativeTick)
    let offset = ceil(...before); if (offset < 0n) offset = 0n
    while (offset < extent) {
      const absolute = add(displacement, multiply([offset, 1n], nativeTick))
      const index = floor(...divide(absolute, period))
      const boundary = divide(subtract(multiply([index + 1n, 1n], period), displacement), nativeTick)
      let after = ceil(...boundary); if (after > extent) after = extent
      if (after <= offset) throw new Error('Recording cycle cannot advance its source clock')
      const local = add(projectStart, subtract(absolute, multiply([index, 1n], period)))
      const position = Number(floor(...divide(local, tick)))
      if (!Number.isSafeInteger(position) || position < 0) throw new Error('Recorded pass exceeds project tick range')
      const residual = subtract(local, multiply([BigInt(position), 1n], tick))
      const region = { cycle: String(index), position, offset: String(offset), extent: String(after - offset), repeat: 1,
        clockOffsetNanoseconds: fraction(add(residual, advance)), ...(component ? { component } : {}),
        ...(component === 'audio' ? { placement: structuredClone(correction.placement), audioChannel: structuredClone(correction.audioChannel) } : {}) }
      captureRegionTime(asset, region); regions.push(region); offset = after
    }
  }
  if (!regions.length) throw new Error('Recorded take ended before the backing began')
  return { regions, alignment: { epoch: checked, sourceOrigin: range.origin, correction: structuredClone(correction),
    passes: regions.map(region => structuredClone(region)) } }
}

function attachLoopTake(project, result, asset, epoch, correction) {
  const { regions, alignment } = recordedLoopRegions(project, asset, epoch, correction)
  const next = structuredClone(result.project)
  next.assets.find(item => item.id === asset.id).recording = alignment
  const used = { lane: new Set(next.lanes.map(item => item.id)), region: new Set(next.clips.map(item => item.id)) }, counters = { lane: 1, region: 1 }
  const fresh = kind => {
    while (used[kind].has(`${kind}-${counters[kind]}`)) counters[kind]++
    const id = `${kind}-${counters[kind]++}`; used[kind].add(id); return id
  }
  // A corrected component may cross one more boundary than its paired stream.
  // Select one performance, never the last audio from one pass and MIDI from
  // another. A missing component in the latest partial pass stays silent.
  const latest = regions.reduce((last, region) => BigInt(region.cycle) > last ? BigInt(region.cycle) : last, 0n)
  for (const region of regions) {
    const name = `${asset.name} · Take ${BigInt(region.cycle) + 1n}${region.component ? ' ' + region.component : ''}`
    const lane = { id: fresh('lane'), name, kind: 'capture', muted: BigInt(region.cycle) !== latest, solo: false }
    next.lanes.push(lane)
    const { cycle, ...clip } = region
    next.clips.push({ ...clip, id: fresh('region'), name, lane: lane.id, asset: asset.id })
  }
  validateArrangement(next)
  return { project: next, asset: asset.id, alignment }
}

export function attachRecordedTake(project, result, epoch, correction = { kind: 'none' }) {
  validateRecordingCorrection(correction)
  if (result.project.assets.find(asset => asset.id === result.asset)?.recording) throw new Error('Recorded take is already attached')
  const asset = result.project.assets.find(asset => asset.id === result.asset)
  recordingCorrectionCapture(correction, asset.manifest)
  if (epoch.loop) return attachLoopTake(project, result, asset, epoch, correction)
  const region = recordedRegion(project, asset, epoch)
  const alignment = { ...region.alignment, correction: structuredClone(correction) }
  // The import and its fresh lane/region form one undoable editor transaction.
  const retained = { ...result.project, assets: result.project.assets.map(item => item === asset ? { ...item, recording: alignment } : item) }
  let next = editArrangement(retained, { kind: 'lane-add', sourceKind: 'capture', name: asset.name })
  next = editArrangement(next, { kind: 'region-add', asset: asset.id, lane: next.lanes.at(-1).id,
    name: asset.name, position: region.position, offset: region.offset, extent: region.extent, repeat: 1 })
  if (correction.kind === 'audio') {
    const id = next.clips.at(-1).id
    next = editArrangement(next, { kind: 'capture-split', id })
    next = editArrangement(next, { kind: 'region-change', id, audioChannel: correction.audioChannel, placement: correction.placement })
  }
  return { project: next, asset: asset.id, alignment }
}
