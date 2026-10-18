import { captureRange, captureRegionTime } from './capture-time.mjs'
import { editArrangement } from './arrangement.mjs'

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
  if (event?.kind !== 'playing' || event.loop || !['mach-host-time', 'mach-nanoseconds'].includes(clock?.kind)) throw new Error('Start arrangement playback before recording')
  uint64(clock.anchor); rational(clock.position); rational(event.duration)
  if (clock.position >= event.duration) throw new Error('Arrangement playback has ended')
  if (clock.kind === 'mach-host-time' && ![clock.numer, clock.denom].every(value => Number.isSafeInteger(value) && value > 0)) throw new Error('Missing playback clock timebase')
  return { clock: structuredClone(clock), duration: event.duration }
}

// Inward placement on the document's quarter-note tick lattice. The complete
// take remains an asset; only its placed region loses sub-tick pre-roll/tail.
// Return the measured rounding error as a rational host-tick count for audit.
export function recordedRegion(project, asset, epoch) {
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

export function attachRecordedTake(project, result, epoch) {
  const asset = result.project.assets.find(asset => asset.id === result.asset)
  const region = recordedRegion(project, asset, epoch)
  // The import and its fresh lane/region form one undoable editor transaction.
  const retained = { ...result.project, assets: result.project.assets.map(item => item === asset ? { ...item, recording: region.alignment } : item) }
  let next = editArrangement(retained, { kind: 'lane-add', sourceKind: 'capture', name: asset.name })
  next = editArrangement(next, { kind: 'region-add', asset: asset.id, lane: next.lanes.at(-1).id,
    name: asset.name, position: region.position, offset: region.offset, extent: region.extent, repeat: 1 })
  return { project: next, asset: asset.id, alignment: region.alignment }
}
