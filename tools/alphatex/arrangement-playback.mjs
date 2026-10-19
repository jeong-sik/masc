import { verifyPhraseSnapshot } from './phrase-arrangement.mjs'
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { arrangementPlaybackSchedule, newArrangement } from './arrangement.mjs'
import { sourceMidiTimeline } from './midi-source-playback.mjs'
import { importArrangementWave, prepareArrangementCapture } from './arrangement-files.mjs'
import { readWaveMetadata } from './wave-file.mjs'
import { captureRange, captureRegionTime } from './capture-time.mjs'
import { projectCapturedPlacement } from './capture-placement.mjs'
import { jsonLines, unpackMidi } from './session-data.mjs'

import { practiceEnabled } from './arrangement-practice.mjs'
import { arrangementLoop, loopMidiRegions, requireLoopTransport } from './arrangement-loop.mjs'

function requireRegionTransport(project) {
  const schedule = arrangementPlaybackSchedule(project)
  if (schedule.some(clip => project.assets.find(asset => asset.id === clip.asset).kind === 'capture')) {
    throw new Error('Captured regions require paired capture preparation')
  }
  return schedule
}

// One compressed region record retains whole source frames. Preparation owns
// private copies, so editing/moving project files cannot change admitted audio.
export async function prepareArrangementWave(project, { sourceRoot, directory, signal } = {}) {
  signal?.throwIfAborted()
  const schedule = requireRegionTransport(project)
  if (!schedule.length) throw new Error('No audible arrangement regions')
  if (schedule.some(clip => project.assets.find(asset => asset.id === clip.asset).kind !== 'wave')) {
    throw new Error('MIDI region playback requires expression-state reconstruction; mute MIDI lanes for WAV playback')
  }
  const temporary = await mkdtemp(join(directory, 'play-'))
  try {
    const assets = []
    for (const id of new Set(schedule.map(clip => clip.asset))) {
      const asset = project.assets.find(asset => asset.id === id)
      const copied = await importArrangementWave(newArrangement(), join(sourceRoot, asset.file),
        { projectPath: join(temporary, 'project.json'), signal })
      const snapshot = copied.project.assets[0]
      if (snapshot.sha256 !== asset.sha256 || !['encoding', 'channels', 'sampleRate', 'bitsPerSample', 'validBits', 'blockAlign', 'frames']
        .every(key => snapshot.metadata[key] === asset.metadata[key])) {
        throw new Error('WAV source changed before playback admission')
      }
      assets.push({ id, path: join(temporary, snapshot.file), sha256: snapshot.sha256, ...snapshot.metadata })
    }
    const loop = arrangementLoop(project)
    const regions = schedule.map(clip => ({ id: clip.id, asset: clip.asset, startSeconds: clip.startSeconds,
      offsetFrames: clip.offset, frameCount: clip.extent, repeat: clip.repeat, ...(loop ? { projectTick: clip.position } : {}) }))
    const duration = loop ? (project.playbackLoop.end - project.playbackLoop.start) / project.ppq * 60 / project.tempo
      : regions.reduce((end, clip) => Math.max(end, clip.startSeconds
        + clip.frameCount / assets.find(asset => asset.id === clip.asset).sampleRate * clip.repeat), 0)
    if (!Number.isFinite(duration) || duration <= 0) throw new Error('Arrangement has no representable audio duration')
    const plan = { schemaVersion: 1, kind: 'wave-arrangement', duration, assets, regions,
      ...(loop ? { loop: { ...project.playbackLoop, ppq: project.ppq, tempo: project.tempo } } : {}) }
    signal?.throwIfAborted()
    const path = join(temporary, 'plan.json')
    await writeFile(path, JSON.stringify(plan), { flag: 'wx', mode: 0o600, signal })
    signal?.throwIfAborted()
    return { path, duration, format: 'wave-arrangement', ...(loop ? { loop: true, originSeconds: loop.start } : {}) }
  } catch (error) { await rm(temporary, { recursive: true, force: true }); throw error }
}

// Sources retain their complete wire timelines. Regions carry only native-time
// trims and finite repeat counts; neither preparation nor playback expands copies.
export async function prepareArrangementMidi(project, { directory, signal, midiOutput, portBindings = [] } = {}) {
  signal?.throwIfAborted()
  const schedule = requireRegionTransport(project)
  if (!schedule.length) throw new Error('No audible arrangement regions')
  if (schedule.some(clip => project.assets.find(asset => asset.id === clip.asset).kind !== 'midi')) {
    throw new Error('Mixed WAV/MIDI arrangement playback needs the shared-clock transport; mute WAV lanes for MIDI playback')
  }
  if (!Array.isArray(portBindings)) throw new Error('Invalid arrangement MIDI port bindings')
  const sources = [], regions = []
  for (const clip of schedule) {
    const asset = project.assets.find(asset => asset.id === clip.asset)
    const identity = JSON.stringify([asset.id, clip.pattern ?? null])
    let source = sources.find(source => source.id === identity)
    if (!source) {
      verifyPhraseSnapshot(asset)
      const selected = portBindings.filter(binding => binding.asset === asset.id).map(({ port, destination }) => ({ port, destination }))
      source = { id: identity, timeline: sourceMidiTimeline(asset.source, { pattern: clip.pattern,
        ...(selected.length ? { portBindings: selected } : { midiOutput }) }) }
      sources.push(source)
    }
    if (clip.durationSeconds <= 0) throw new Error('MIDI region playback requires a positive source span')
    regions.push({ id: clip.id, source: identity, startSeconds: clip.startSeconds,
      sourceStart: clip.sourceStartSeconds, sourceEnd: clip.sourceEndSeconds, repeatCount: clip.repeat })
  }
  const bindings = [...new Set(sources.flatMap(source => source.timeline.bindings.map(binding => binding.destination)))]
    .map((destination, port) => ({ port, destination }))
  const loop = arrangementLoop(project), selected = loopMidiRegions(regions, loop)
  const selectedSources = sources.filter(source => selected.some(region => region.source === source.id))
  // The cycle contains the native arithmetic endpoints of the selected spans.
  // Outward projection may add a representable silent tail; it never broadens
  // the source trims or admits events outside the requested loop window.
  const duration = loop ? selected.reduce((end, region) => Math.max(end, region.startSeconds
    + (region.sourceEnd - region.sourceStart) * region.repeatCount), loop.duration)
    : schedule.reduce((end, clip) => Math.max(end, clip.endSeconds), 0)
  if (!Number.isFinite(duration) || duration <= 0) throw new Error('Arrangement has no representable MIDI duration')
  const temporary = await mkdtemp(join(directory, 'play-'))
  try {
    signal?.throwIfAborted()
    const path = join(temporary, 'plan.json')
    await writeFile(path, JSON.stringify({ schemaVersion: 3, duration, sources: selectedSources, regions: selected }), { flag: 'wx', mode: 0o600, signal })
    signal?.throwIfAborted()
    return { path, duration, format: 'midi-arrangement', bindings, midiOutput: bindings[0].destination,
      ...(loop ? { loop: true, originSeconds: loop.start } : {}) }
  } catch (error) { await rm(temporary, { recursive: true, force: true }); throw error }
}

// A route expresses the user's output intent independently of lane mute/solo.
export function arrangementRoute({ output, midiOutput } = {}) {
  return output !== undefined && midiOutput !== undefined ? { kind: 'mixed', output, midiOutput, portBindings: [] }
    : midiOutput !== undefined ? { kind: 'midi', midiOutput, portBindings: [] } : { kind: 'audio', output }
}
export function selectArrangementRoute(route, effect) {
  switch (effect.kind) {
    case 'output': return { kind: 'audio', output: effect.path }
    case 'mixed-output': return { kind: 'mixed', output: effect.path, midiOutput: route.midiOutput, portBindings: route.portBindings ?? [], ...(route.sourceBindings ? { sourceBindings: route.sourceBindings } : {}) }
    case 'midi-output': return { ...(route.kind === 'mixed' ? { kind: 'mixed', output: route.output } : { kind: 'midi' }), ...(route.sourceBindings ? { sourceBindings: route.sourceBindings } : {}), midiOutput: effect.destination, portBindings: [] }
    case 'midi-port': return { ...(route.midiOutput !== undefined ? { midiOutput: route.midiOutput } : {}), ...(route.kind === 'mixed' ? { kind: 'mixed', output: route.output } : { kind: 'midi' }), ...(route.sourceBindings ? { sourceBindings: route.sourceBindings } : {}), portBindings: [
      ...(route.portBindings ?? []).filter(binding => binding.asset !== effect.asset || binding.port !== effect.port),
      { asset: effect.asset, port: effect.port, destination: effect.destination }] }
    case 'midi-source': return { kind: 'mixed', output: route.output, midiOutput: route.midiOutput, portBindings: route.portBindings ?? [], sourceBindings: [
      ...(route.sourceBindings ?? []).filter(binding => binding.asset !== effect.asset || binding.source !== effect.source),
      { asset: effect.asset, source: effect.source, destination: effect.destination }] }
    default: throw new Error('Unknown arrangement output selection')
  }
}
export function arrangementPlaybackRequest(project, route) {
  const schedule = arrangementPlaybackSchedule(project), audible = new Set(schedule.map(clip => clip.asset))
  const assets = project.assets.filter(asset => audible.has(asset.id)), kinds = new Set(assets.map(asset => asset.kind))
  if (!kinds.size) throw new Error('No audible arrangement regions')
  if (practiceEnabled(project) && kinds.has('midi') && (route.kind !== 'mixed' || !route.output)) throw new Error('Choose :mixed-output AUDIO_UID for the practice click and MIDI backing')
  if (kinds.has('capture')) {
    const notes = schedule.some(clip => clip.component !== 'audio' && assets.some(asset => asset.id === clip.asset && asset.kind === 'capture' && BigInt(asset.manifest.midiPacketCount) > 0n))
    if (project.playbackLoop && !notes && !kinds.has('midi')) {
      if (route.kind === 'midi') throw new Error('Choose an audio output for audible captured audio')
      return { kind: 'prepare-audio', output: route.output }
    }
    if (route.kind === 'midi' || (notes || kinds.has('midi')) && route.kind !== 'mixed') throw new Error('Select :mixed-output AUDIO_UID and MIDI destinations for paired captures')
    return { kind: 'prepare-capture', output: route.output, midiOutput: route.midiOutput, sourceBindings: route.sourceBindings ?? [], ...(kinds.has('midi') ? { portBindings: route.portBindings ?? [] } : {}) }
  }
  if (kinds.size > 1 && route.kind !== 'mixed') throw new Error('Select :mixed-output AUDIO_UID and MIDI destinations for mixed playback')
  if (kinds.has('wave') && route.kind === 'midi') throw new Error('Choose an audio output for audible WAV regions')
  if (kinds.has('midi') && route.kind === 'audio') throw new Error('Choose a MIDI destination for audible MIDI regions')
  return { kind: kinds.size > 1 ? 'prepare-mixed' : kinds.has('wave') ? 'prepare-wave' : 'prepare-midi',
    ...(kinds.has('wave') || practiceEnabled(project) ? { output: route.output } : {}),
    ...(kinds.has('midi') ? { midiOutput: route.midiOutput, portBindings: route.portBindings } : {}) }
}

export async function prepareArrangementMixed(project, options = {}) {
  options.signal?.throwIfAborted()
  const schedule = requireRegionTransport(project), audible = new Set(schedule.map(clip => clip.id))
  const kinds = new Map(project.assets.map(asset => [asset.id, asset.kind]))
  const part = kind => ({ ...project, clips: project.clips.filter(clip => audible.has(clip.id) && kinds.get(clip.asset) === kind) })
  // The mixed owner samples original MIDI regions in absolute project time.
  // It shares the authored WAV cycle instead of repeating an outward-projected
  // MIDI trim envelope, which could otherwise acquire a different period.
  const midiProject = part('midi')
  delete midiProject.playbackLoop
  const midi = await prepareArrangementMidi(midiProject, options)
  let wave
  try {
    wave = await prepareArrangementWave(part('wave'), options)
    const [audioPlan, midiPlan] = await Promise.all([readFile(wave.path, { encoding: 'utf8', signal: options.signal }),
      readFile(midi.path, { encoding: 'utf8', signal: options.signal })])
    const audio = JSON.parse(audioPlan), notes = JSON.parse(midiPlan)
    const duration = audio.loop ? audio.duration : Math.max(audio.duration, notes.duration)
    if (!audio.loop) notes.duration = duration
    options.signal?.throwIfAborted()
    await writeFile(wave.path, JSON.stringify({ ...audio, schemaVersion: 2, kind: 'mixed-arrangement', duration, midi: notes }),
      { mode: 0o600, signal: options.signal })
    options.signal?.throwIfAborted()
    return { ...wave, duration, format: 'mixed-arrangement', bindings: midi.bindings, midiOutput: midi.midiOutput }
  } catch (error) {
    if (wave) await rm(dirname(wave.path), { recursive: true, force: true })
    throw error
  } finally { await rm(dirname(midi.path), { recursive: true, force: true }) }
}

// Both routes snapshot complete captures once. The paired route consumes the
// same private files; the explicit audio audition selects only their WAV data.
async function snapshotAudio(project, schedule, { sourceRoot, temporary, signal }) {
  const byID = new Map(project.assets.map(asset => [asset.id, asset])), assets = [], regions = [], captures = new Map()
  for (const id of new Set(schedule.map(clip => clip.asset))) {
    const asset = byID.get(id)
    if (asset.kind === 'capture') {
      const snapshot = await prepareArrangementCapture(project, id, { sourceRoot, directory: temporary, signal })
      captures.set(id, snapshot.directory)
      const path = join(snapshot.directory, 'audio.wav'), metadata = await readWaveMetadata(path, {}, { signal })
      const frames = Number(metadata.frames)
      if (!Number.isSafeInteger(frames)) throw new Error('Captured WAV exceeds exact native plan frame precision')
      if (frames) assets.push({ id, path, sha256: asset.parts.audio.sha256, ...metadata, frames })
    } else {
      const snapshot = await prepareArrangementWave({ ...project, clips: project.clips.filter(clip => clip.asset === id) },
        { sourceRoot, directory: temporary, signal })
      const plan = JSON.parse(await readFile(snapshot.path, { encoding: 'utf8', signal }))
      assets.push(...plan.assets); regions.push(...plan.regions)
    }
  }
  for (let clip of schedule) {
    const asset = byID.get(clip.asset)
    if (asset.kind !== 'capture' || clip.component === 'midi' || !clip.audio) continue
    if (project.playbackLoop && !clip.startNanoseconds) clip = projectCapturedPlacement(project, asset, clip)[0]
    const frame = text => {
      const value = Number(text)
      if (!Number.isSafeInteger(value)) throw new Error('Captured WAV exceeds exact native plan frame precision')
      return value
    }
    regions.push({ id: clip.id, asset: clip.asset, startSeconds: clip.startSeconds,
      offsetFrames: frame(clip.audio.offsetFrames), frameCount: frame(clip.audio.frameCount), repeat: clip.repeat,
      captureClock: { ...clip.sourceClock, firstAudioHostTime: asset.manifest.clock.firstAudioHostTime },
      ...(project.playbackLoop ? { startNanoseconds: clip.startNanoseconds } : {}),
      ...(clip.component ? { component: clip.component } : {}),
      ...(clip.placement?.kind === 'calibrated' ? { calibrationOutput: { id: clip.placement.profile.output.id,
        sampleRate: clip.placement.profile.output.sampleRate, bufferFrames: clip.placement.profile.output.bufferFrames } } : {}),
      ...(clip.audioChannel ? { audioChannel: { ...clip.audioChannel } } : {}) })
  }
  const used = new Set(regions.map(region => region.asset)), duration = schedule.reduce((end, clip) => Math.max(end, clip.endSeconds), 0)
  return { assets: assets.filter(asset => used.has(asset.id)), regions, duration, captures }
}
export async function prepareArrangementAudio(project, { sourceRoot, directory, signal } = {}) {
  signal?.throwIfAborted()
  const loop = arrangementLoop(project)
  if (loop && practiceEnabled(project)) throw new Error('Continuous looping with count-in or metronome is not connected yet; use :loop off for practice clicks')
  const schedule = arrangementPlaybackSchedule(project)
  if (!schedule.length) throw new Error('No audible arrangement regions')
  if (schedule.some(clip => project.assets.find(asset => asset.id === clip.asset).kind === 'midi')) throw new Error('Audio-only audition cannot synthesize MIDI assets; mute those lanes')
  const temporary = await mkdtemp(join(directory, 'audio-play-'))
  try {
    const { assets, regions, duration: sourceDuration } = await snapshotAudio(project, schedule, { sourceRoot, temporary, signal })
    const duration = loop ? (project.playbackLoop.end - project.playbackLoop.start) / project.ppq * 60 / project.tempo : sourceDuration
    const path = join(temporary, 'plan.json')
    await writeFile(path, JSON.stringify({ schemaVersion: 4, kind: 'capture-audio-arrangement', duration, assets, regions,
      ...(loop ? { loop: { ...project.playbackLoop, ppq: project.ppq, tempo: project.tempo } } : {}) }), { flag: 'wx', mode: 0o600, signal })
    signal?.throwIfAborted()
    return { path, duration, format: 'capture-audio-arrangement', ...(loop ? { loop: true, originSeconds: loop.start } : {}) }
  } catch (error) { await rm(temporary, { recursive: true, force: true }); throw error }
}

export async function prepareArrangementCaptureRegions(project, { sourceRoot, directory, signal, midiOutput, sourceBindings = [], portBindings = [] } = {}) {
  requireLoopTransport(project)
  signal?.throwIfAborted()
  const schedule = arrangementPlaybackSchedule(project), byID = new Map(project.assets.map(asset => [asset.id, asset]))
  if (!schedule.length) throw new Error('No audible arrangement regions')
  if (!schedule.some(clip => byID.get(clip.asset).kind === 'capture')) {
    throw new Error('Paired capture preparation requires captured lanes')
  }
  const destination = value => {
    const number = Number(value)
    if (typeof value !== 'string' || !Number.isInteger(number) || String(number) !== value || number < -2147483648 || number > 2147483647) throw new Error('Choose an exact MIDI destination for every captured source')
    return value
  }
  if (!Array.isArray(sourceBindings)) throw new Error('Invalid captured source bindings')
  const selected = new Set()
  for (const binding of sourceBindings) {
    const asset = byID.get(binding?.asset), identity = JSON.stringify([binding?.asset, binding?.source])
    if (asset?.kind !== 'capture' || typeof binding.source !== 'string' || !binding.source || selected.has(identity)) throw new Error('Invalid or duplicate captured asset/source binding')
    destination(binding.destination); selected.add(identity)
  }
  if (midiOutput !== undefined) destination(midiOutput)
  const temporary = await mkdtemp(join(directory, 'capture-region-play-'))
  try {
    const { assets, regions, captures } = await snapshotAudio(project, schedule.filter(clip => byID.get(clip.asset).kind !== 'midi'), { sourceRoot, temporary, signal })
    const duration = schedule.reduce((end, clip) => Math.max(end, clip.endSeconds), 0)
    const sources = [], notes = []
    for (const [id, snapshot] of captures) {
      if (!schedule.some(clip => clip.asset === id && clip.component !== 'audio')) continue
      const asset = byID.get(id), packets = [], used = new Set(), range = captureRange(asset)
      for await (const row of jsonLines(join(snapshot, 'midi.ump.jsonl'), { signal })) {
        unpackMidi(row)
        if (typeof row.hostTime !== 'string' || !/^(0|[1-9][0-9]*)$/.test(row.hostTime) || BigInt(row.hostTime) > 0xffffffffffffffffn || !row.words.length) throw new Error('Invalid captured packet host time or empty UMP')
        used.add(row.source); packets.push(row)
      }
      const explicit = sourceBindings.filter(binding => binding.asset === id)
      if (explicit.some(binding => !used.has(binding.source))) throw new Error('Binding names an unused captured MIDI source')
      const bindings = [...used].map(source => ({ source, destination: destination(explicit.find(binding => binding.source === source)?.destination ?? midiOutput) }))
      sources.push({ id, extent: range.extent, timeline: { schemaVersion: 4,
        duration: captureRegionTime(asset, { offset: '0', extent: range.extent }).durationSeconds,
        clock: { origin: range.origin, numer: asset.manifest.clock.numer, denom: asset.manifest.clock.denom }, bindings, packets } })
    }
    const bindings = [...new Set(sources.flatMap(source => source.timeline.bindings.map(binding => binding.destination)))].map((destination, port) => ({ port, destination }))
    for (const clip of schedule) if (byID.get(clip.asset).kind === 'capture' && clip.component !== 'audio') {
      notes.push({ id: clip.id, source: clip.asset, startSeconds: clip.startSeconds, offset: clip.offset, extent: clip.extent, repeatCount: clip.repeat, ...(clip.component ? { component: clip.component } : {}),
      ...(clip.startNanoseconds ? { startNanoseconds: clip.startNanoseconds } : {}) })
    }
    let midi, smfBindings = []
    if (schedule.some(clip => byID.get(clip.asset).kind === 'midi')) {
      const source = await prepareArrangementMidi({ ...project, clips: project.clips.filter(clip => byID.get(clip.asset).kind === 'midi') },
        { directory: temporary, signal, midiOutput, portBindings })
      midi = JSON.parse(await readFile(source.path, { encoding: 'utf8', signal })); midi.duration = duration; smfBindings = source.bindings
    }
    const paired = bindings.length > 0 || midi !== undefined, format = midi ? 'hybrid-arrangement' : paired ? 'capture-arrangement' : 'capture-audio-arrangement', path = join(temporary, 'plan.json')
    const outputs = midi ? [...smfBindings.map(binding => ({ ...binding, protocol: 1 })), ...bindings.map(binding => ({ ...binding, protocol: 2 }))]
      .map((binding, port) => ({ ...binding, port })) : bindings
    signal?.throwIfAborted()
    await writeFile(path, JSON.stringify({ schemaVersion: midi ? 6 : paired ? 5 : 4, kind: format, duration, assets, regions, ...(midi ? { midi } : {}),
      ...(paired ? { umpRegions: { schemaVersion: 1, duration, sources, regions: notes } } : {}) }), { flag: 'wx', mode: 0o600, signal })
    signal?.throwIfAborted()
    return { path, duration, format, ...(paired ? { bindings: outputs, midiOutput: outputs[0].destination } : {}) }
  } catch (error) { await rm(temporary, { recursive: true, force: true }); throw error }
}
