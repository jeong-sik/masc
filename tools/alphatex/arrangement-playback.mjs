import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { arrangementSchedule, newArrangement } from './arrangement.mjs'
import { sourceMidiTimeline } from './midi-source-playback.mjs'
import { importArrangementWave, prepareArrangementCapture } from './arrangement-files.mjs'
import { readWaveMetadata } from './wave-file.mjs'

function requireRegionTransport(project) {
  const schedule = arrangementSchedule(project)
  if (schedule.some(clip => project.assets.find(asset => asset.id === clip.asset).kind === 'capture')) {
    throw new Error('Captured-region playback is not connected yet; mute captured lanes or use :open-take for paired source playback')
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
    const regions = schedule.map(clip => ({ id: clip.id, asset: clip.asset, startSeconds: clip.startSeconds,
      offsetFrames: clip.offset, frameCount: clip.extent, repeat: clip.repeat }))
    const duration = regions.reduce((end, clip) => Math.max(end, clip.startSeconds
      + clip.frameCount / assets.find(asset => asset.id === clip.asset).sampleRate * clip.repeat), 0)
    if (!Number.isFinite(duration) || duration <= 0) throw new Error('Arrangement has no representable audio duration')
    const plan = { schemaVersion: 1, kind: 'wave-arrangement', duration, assets, regions }
    signal?.throwIfAborted()
    const path = join(temporary, 'plan.json')
    await writeFile(path, JSON.stringify(plan), { flag: 'wx', mode: 0o600, signal })
    signal?.throwIfAborted()
    return { path, duration, format: 'wave-arrangement' }
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
  const duration = schedule.reduce((end, clip) => Math.max(end, clip.endSeconds), 0)
  if (!Number.isFinite(duration) || duration <= 0) throw new Error('Arrangement has no representable MIDI duration')
  const temporary = await mkdtemp(join(directory, 'play-'))
  try {
    signal?.throwIfAborted()
    const path = join(temporary, 'plan.json')
    await writeFile(path, JSON.stringify({ schemaVersion: 3, duration, sources, regions }), { flag: 'wx', mode: 0o600, signal })
    signal?.throwIfAborted()
    return { path, duration, format: 'midi-arrangement', bindings, midiOutput: bindings[0].destination }
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
    case 'mixed-output': return { kind: 'mixed', output: effect.path, midiOutput: route.midiOutput, portBindings: route.portBindings ?? [] }
    case 'midi-output': return { ...(route.kind === 'mixed' ? { kind: 'mixed', output: route.output } : { kind: 'midi' }), midiOutput: effect.destination, portBindings: [] }
    case 'midi-port': return { ...(route.kind === 'mixed' ? { kind: 'mixed', output: route.output } : { kind: 'midi' }), portBindings: [
      ...(route.portBindings ?? []).filter(binding => binding.asset !== effect.asset || binding.port !== effect.port),
      { asset: effect.asset, port: effect.port, destination: effect.destination }] }
    default: throw new Error('Unknown arrangement output selection')
  }
}
export function arrangementPlaybackRequest(project, route) {
  const kinds = new Set(requireRegionTransport(project).map(clip => project.assets.find(asset => asset.id === clip.asset).kind))
  if (!kinds.size) throw new Error('No audible arrangement regions')
  if (kinds.size > 1 && route.kind !== 'mixed') throw new Error('Select :mixed-output AUDIO_UID and MIDI destinations for mixed playback')
  if (kinds.has('wave') && route.kind === 'midi') throw new Error('Choose an audio output for audible WAV regions')
  if (kinds.has('midi') && route.kind === 'audio') throw new Error('Choose a MIDI destination for audible MIDI regions')
  return { kind: kinds.size > 1 ? 'prepare-mixed' : kinds.has('wave') ? 'prepare-wave' : 'prepare-midi',
    ...(kinds.has('wave') ? { output: route.output } : {}),
    ...(kinds.has('midi') ? { midiOutput: route.midiOutput, portBindings: route.portBindings } : {}) }
}

export async function prepareArrangementMixed(project, options = {}) {
  options.signal?.throwIfAborted()
  requireRegionTransport(project)
  const kinds = new Map(project.assets.map(asset => [asset.id, asset.kind]))
  const part = kind => ({ ...project, clips: project.clips.filter(clip => kinds.get(clip.asset) === kind) })
  const midi = await prepareArrangementMidi(part('midi'), options)
  let wave
  try {
    wave = await prepareArrangementWave(part('wave'), options)
    const [audioPlan, midiPlan] = await Promise.all([readFile(wave.path, { encoding: 'utf8', signal: options.signal }),
      readFile(midi.path, { encoding: 'utf8', signal: options.signal })])
    const audio = JSON.parse(audioPlan), notes = JSON.parse(midiPlan)
    const duration = Math.max(audio.duration, notes.duration)
    notes.duration = duration
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

// Explicit audio-only audition. Capture clips retain their paired source parts,
// while this route deliberately selects only WAV. Regular play still requires
// a paired region transport and does not silently omit UMP.
export async function prepareArrangementAudio(project, { sourceRoot, directory, signal } = {}) {
  signal?.throwIfAborted()
  const schedule = arrangementSchedule(project), byID = new Map(project.assets.map(asset => [asset.id, asset]))
  if (!schedule.length) throw new Error('No audible arrangement regions')
  if (schedule.some(clip => byID.get(clip.asset).kind === 'midi')) throw new Error('Audio-only audition cannot synthesize MIDI assets; mute those lanes')
  const temporary = await mkdtemp(join(directory, 'audio-play-'))
  try {
    const assets = [], regions = []
    for (const id of new Set(schedule.map(clip => clip.asset))) {
      const asset = byID.get(id)
      if (asset.kind === 'capture') {
        const snapshot = await prepareArrangementCapture(project, id, { sourceRoot, directory: temporary, signal })
        const path = join(snapshot.directory, 'audio.wav'), metadata = await readWaveMetadata(path, {}, { signal })
        const frames = Number(metadata.frames)
        if (!Number.isSafeInteger(frames)) throw new Error('Captured WAV exceeds exact native plan frame precision')
        // A source with no complete audio frames still owns its silent interval.
        if (frames) assets.push({ id, path, sha256: asset.parts.audio.sha256, ...metadata, frames })
      } else {
        const snapshot = await prepareArrangementWave({ ...project, clips: project.clips.filter(clip => clip.asset === id) },
          { sourceRoot, directory: temporary, signal })
        const plan = JSON.parse(await readFile(snapshot.path, { encoding: 'utf8', signal }))
        assets.push(...plan.assets); regions.push(...plan.regions)
      }
    }
    for (const clip of schedule) {
      const asset = byID.get(clip.asset)
      if (asset.kind !== 'capture' || !clip.audio) continue
      const frame = text => {
        const value = Number(text)
        if (!Number.isSafeInteger(value)) throw new Error('Captured WAV exceeds exact native plan frame precision')
        return value
      }
      regions.push({ id: clip.id, asset: clip.asset, startSeconds: clip.startSeconds,
        offsetFrames: frame(clip.audio.offsetFrames), frameCount: frame(clip.audio.frameCount), repeat: clip.repeat,
        captureClock: { ...clip.sourceClock, firstAudioHostTime: asset.manifest.clock.firstAudioHostTime } })
    }
    // Snapshots for silent-only cuts are still verified, but need no audio node.
    const used = new Set(regions.map(region => region.asset))
    const duration = schedule.reduce((end, clip) => Math.max(end, clip.endSeconds), 0)
    const path = join(temporary, 'plan.json')
    await writeFile(path, JSON.stringify({ schemaVersion: 4, kind: 'capture-audio-arrangement', duration,
      assets: assets.filter(asset => used.has(asset.id)), regions }), { flag: 'wx', mode: 0o600, signal })
    signal?.throwIfAborted()
    return { path, duration, format: 'capture-audio-arrangement' }
  } catch (error) { await rm(temporary, { recursive: true, force: true }); throw error }
}
