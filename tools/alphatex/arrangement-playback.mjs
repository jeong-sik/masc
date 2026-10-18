import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { arrangementSchedule, newArrangement } from './arrangement.mjs'
import { sourceMidiTimeline } from './midi-source-playback.mjs'
import { importArrangementWave } from './arrangement-files.mjs'

// One compressed region record retains whole source frames. Preparation owns
// private copies, so editing/moving project files cannot change admitted audio.
export async function prepareArrangementWave(project, { sourceRoot, directory, signal } = {}) {
  signal?.throwIfAborted()
  const schedule = arrangementSchedule(project)
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
  const schedule = arrangementSchedule(project)
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
