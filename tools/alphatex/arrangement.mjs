import { validateCapturedSource } from './captured-source.mjs'
import { captureRegionTime } from './capture-time.mjs'
import { validateMidiSource, midiSourcePattern } from './midi-source.mjs'
import { PPQ } from './sequencer-project.mjs'
import { validateCapturePlacement, capturePlacementStart, projectCapturedPlacement } from './capture-placement.mjs'

const integer = (value, name, minimum = 0) => {
  if (!Number.isSafeInteger(value) || value < minimum) throw new Error(`Invalid ${name}`)
  return value
}
const text = (value, name) => {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`Invalid ${name}`)
}
export function arrangementID(items, prefix) {
  const used = new Set(items.map(item => item.id))
  let number = 1
  while (used.has(`${prefix}-${number}`)) number++
  return `${prefix}-${number}`
}
export function newArrangement({ title = 'Arrangement', tempo = 100 } = {}) {
  return validateArrangement({ schemaVersion: 1, kind: 'arrangement', ppq: PPQ, title, tempo,
    meter: [4, 4], assets: [], lanes: [], clips: [] })
}
function unique(items, name) {
  if (!Array.isArray(items)) throw new Error(`Invalid arrangement ${name}`)
  const ids = new Set()
  for (const item of items) {
    text(item?.id, `${name} identity`)
    if (ids.has(item.id)) throw new Error(`Duplicate ${name} identity`)
    ids.add(item.id)
  }
}
export function validateArrangementAsset(asset) {
  text(asset?.id, 'asset identity'); text(asset.name, 'asset name')
  switch (asset.kind) {
    case 'midi': validateMidiSource(asset.source); break
    case 'capture': validateCapturedSource(asset); break
    case 'wave': {
      if (typeof asset.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(asset.sha256)
          || asset.file !== `assets/${asset.sha256}.wav`) throw new Error('Invalid portable WAV identity/path')
      const info = asset.metadata
      integer(info?.sampleRate, 'WAV sample rate', 1); integer(info.channels, 'WAV channels', 1)
      integer(info.frames, 'WAV source frames'); integer(info.bitsPerSample, 'WAV sample bits', 1)
      integer(info.validBits, 'WAV valid sample bits', 1); integer(info.blockAlign, 'WAV block alignment', 1)
      if (!['pcm', 'float'].includes(info.encoding) || info.bitsPerSample % 8 || info.validBits > info.bitsPerSample
          || info.blockAlign !== info.channels * info.bitsPerSample / 8
          || info.encoding === 'float' && ![32, 64].includes(info.bitsPerSample)) throw new Error('Invalid WAV source format')
      break
    }
    default: throw new Error('Unknown arrangement asset kind')
  }
  return asset
}
// Source positions remain whole native ticks or sample frames. Project positions
// are quarter-note ticks. A region runs at native speed; there is no implicit warp.
export function sourceSecondsAtTick(performance, tick) {
  integer(tick, 'source MIDI tick')
  if (tick > performance.ticks) throw new Error('MIDI region exceeds its source pattern')
  const events = performance.events
  let low = 0, high = events.length
  while (low < high) {
    const mid = Math.floor((low + high) / 2)
    if (events[mid].tick <= tick) low = mid + 1
    else high = mid
  }
  const before = events[low - 1] ?? { tick: 0, seconds: 0 }, after = events[low]
  if (!after || before.tick === tick) return before.seconds
  return before.seconds + (after.seconds - before.seconds) * (tick - before.tick) / (after.tick - before.tick)
}
export function arrangementClipTime(project, clip) {
  const asset = project.assets.find(asset => asset.id === clip.asset)
  if (!asset) throw new Error('Region source is missing')
  integer(clip.position, 'region project position')
  integer(clip.repeat, 'region repeat count', 1)
  let sourceStart, sourceEnd, duration, capture
  switch (asset.kind) {
  case 'capture': {
    if (clip.pattern !== undefined) throw new Error('Captured regions do not have MIDI patterns')
    if (clip.component !== undefined && !['audio', 'midi'].includes(clip.component)) throw new Error('Unknown captured region component')
    if (clip.placement !== undefined) {
      if (!clip.component) throw new Error('Split captured audio and MIDI before correcting one component')
      validateCapturePlacement(clip.placement)
    }
    capture = captureRegionTime(asset, clip)
    sourceStart = capture.sourceStartSeconds; sourceEnd = capture.sourceEndSeconds; duration = capture.durationSeconds
    break
  }
  case 'wave': {
    integer(clip.offset, 'region source offset'); integer(clip.extent, 'region source extent', 1)
    if (clip.pattern !== undefined) throw new Error('WAV regions do not have MIDI patterns')
    if (clip.offset + clip.extent > asset.metadata.frames || !Number.isSafeInteger(clip.offset + clip.extent)) {
      throw new Error('WAV region exceeds its source frames')
    }
    sourceStart = clip.offset / asset.metadata.sampleRate
    sourceEnd = (clip.offset + clip.extent) / asset.metadata.sampleRate
    break
  }
  case 'midi': {
    integer(clip.offset, 'region source offset'); integer(clip.extent, 'region source extent')
    const performance = midiSourcePattern(asset.source, { pattern: clip.pattern })
    sourceStart = sourceSecondsAtTick(performance, clip.offset)
    sourceEnd = sourceSecondsAtTick(performance, integer(clip.offset + clip.extent, 'region MIDI source end'))
    break
  }
  default: throw new Error('Unknown region source kind')
  }
  if (asset.kind !== 'capture' && (clip.component !== undefined || clip.placement !== undefined)) throw new Error('Component correction requires a captured source')
  const position = asset.kind === 'capture' && clip.placement ? capturePlacementStart(project, clip) : clip.position / project.ppq * 60 / project.tempo
  duration ??= sourceEnd - sourceStart
  const end = position + duration * clip.repeat
  if (![position, sourceStart, sourceEnd, duration, end].every(Number.isFinite)) throw new Error('Region time is not representable')
  return { startSeconds: position, sourceStartSeconds: sourceStart, sourceEndSeconds: sourceEnd, durationSeconds: duration, endSeconds: end,
    ...(capture ? { sourceClock: capture.sourceClock, audio: capture.audio } : {}) }
}
export function validateArrangement(project) {
  if (project?.schemaVersion !== 1 || project.kind !== 'arrangement' || project.ppq !== PPQ) throw new Error('Unsupported arrangement document')
  text(project.title, 'arrangement title')
  if (!Number.isFinite(project.tempo) || project.tempo <= 0) throw new Error('Invalid arrangement tempo')
  if (!Array.isArray(project.meter) || project.meter.length !== 2) throw new Error('Invalid arrangement meter')
  integer(project.meter[0], 'meter numerator', 1)
  integer(project.meter[1], 'meter denominator', 1)
  const denominator = BigInt(project.meter[1])
  if ((denominator & (denominator - 1n)) !== 0n) throw new Error('Arrangement meter denominator must be a power of two')
  unique(project.assets, 'asset'); unique(project.lanes, 'lane'); unique(project.clips, 'region')
  for (const asset of project.assets) validateArrangementAsset(asset)
  const assets = new Map(project.assets.map(asset => [asset.id, asset])), lanes = new Map(project.lanes.map(lane => [lane.id, lane]))
  for (const lane of project.lanes) {
    text(lane.name, 'lane name')
    if (!['wave', 'midi', 'capture'].includes(lane.kind) || typeof lane.muted !== 'boolean' || typeof lane.solo !== 'boolean') throw new Error('Invalid arrangement lane')
  }
  for (const clip of project.clips) {
    text(clip.name, 'region name')
    const asset = assets.get(clip.asset), lane = lanes.get(clip.lane)
    if (!asset || !lane || lane.kind !== asset.kind) throw new Error('Region source and lane kinds must match')
    arrangementClipTime(project, clip)
  }
  return project
}
export function editArrangement(project, edit) {
  validateArrangement(project)
  const next = structuredClone(project)
  const lane = id => {
    const found = next.lanes.find(lane => lane.id === id)
    if (!found) throw new Error('Selected arrangement lane is missing')
    return found
  }
  const region = id => {
    const found = next.clips.find(clip => clip.id === id)
    if (!found) throw new Error('Selected region is missing')
    return found
  }
  switch (edit.kind) {
    case 'asset-add': next.assets.push(structuredClone(edit.asset)); break
    case 'lane-add': next.lanes.push({ id: arrangementID(next.lanes, 'lane'), name: edit.name,
      kind: edit.sourceKind, muted: false, solo: false }); break
    case 'lane-remove': lane(edit.id); next.lanes = next.lanes.filter(item => item.id !== edit.id); next.clips = next.clips.filter(clip => clip.lane !== edit.id); break
    case 'lane-name': lane(edit.id).name = edit.name; break
    case 'lane-mute': lane(edit.id).muted = !lane(edit.id).muted; break
    case 'lane-solo': lane(edit.id).solo = !lane(edit.id).solo; break
    case 'region-add': next.clips.push({ id: arrangementID(next.clips, 'region'), name: edit.name,
      asset: edit.asset, lane: edit.lane, position: edit.position, offset: edit.offset, extent: edit.extent,
      repeat: edit.repeat ?? 1, ...(edit.pattern === undefined ? {} : { pattern: edit.pattern }),
      ...(edit.component === undefined ? {} : { component: edit.component }), ...(edit.placement === undefined ? {} : { placement: structuredClone(edit.placement) }) }); break
    case 'capture-split': {
      const original = region(edit.id), asset = next.assets.find(asset => asset.id === original.asset)
      if (asset?.kind !== 'capture' || original.component !== undefined) throw new Error('Choose a paired captured region to split')
      const id = arrangementID(next.lanes, 'lane')
      const previous = lane(original.lane)
      next.lanes.push({ id, name: `${original.name} MIDI`, kind: 'capture', muted: previous.muted, solo: previous.solo })
      original.component = 'audio'
      next.clips.push({ ...original, id: arrangementID(next.clips, 'region'), component: 'midi', lane: id, name: `${original.name} MIDI` })
      break
    }
    case 'region-change': {
      const clip = region(edit.id)
      for (const key of Object.keys(edit)) {
        if (['kind', 'id'].includes(key)) continue
        if (!['name', 'lane', 'position', 'offset', 'extent', 'repeat', 'pattern', 'component', 'placement'].includes(key)) throw new Error('Unknown region edit field')
        clip[key] = edit[key]
      }
      break
    }
    case 'region-remove': region(edit.id); next.clips = next.clips.filter(clip => clip.id !== edit.id); break
    case 'region-duplicate': {
      const original = region(edit.id)
      next.clips.push({ ...original, id: arrangementID(next.clips, 'region'), position: edit.position }); break
    }
    case 'title': next.title = edit.title; break
    case 'tempo': next.tempo = edit.tempo; break
    case 'meter': next.meter = [...edit.meter]; break
    default: throw new Error('Unknown arrangement edit')
  }
  return validateArrangement(next)
}
export function arrangementSchedule(project, { all = false } = {}) {
  validateArrangement(project)
  const solo = project.lanes.some(lane => lane.solo)
  const lanes = new Set(project.lanes.filter(lane => all || !lane.muted && (!solo || lane.solo)).map(lane => lane.id))
  return project.clips.filter(clip => lanes.has(clip.lane)).map(clip => ({ ...clip, ...arrangementClipTime(project, clip) }))
    .sort((a, b) => a.startSeconds - b.startSeconds)
}

export function arrangementPlaybackSchedule(project) {
  const reserved = [...project.clips], result = []
  for (const clip of arrangementSchedule(project)) {
    const asset = project.assets.find(asset => asset.id === clip.asset)
    const parts = asset.kind === 'capture' && clip.placement ? projectCapturedPlacement(project, asset, clip) : [clip]
    for (const [index, part] of parts.entries()) {
      const id = index ? arrangementID(reserved, 'projection') : clip.id
      reserved.push({ id }); result.push({ ...part, id })
    }
  }
  return result.sort((a, b) => a.startSeconds - b.startSeconds)
}
