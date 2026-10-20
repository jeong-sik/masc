import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises'
import { createReadStream } from 'node:fs'
import { join } from 'node:path'
import { createHash, randomUUID } from 'node:crypto'
import { arrangementPlaybackSchedule } from './arrangement.mjs'
import { arrangementLoop } from './arrangement-loop.mjs'
import { arrangementVstAssets, arrangementPlaybackRequest, prepareArrangementWave, prepareArrangementMidi,
  prepareArrangementMixed, prepareArrangementAudio, prepareArrangementCaptureRegions } from './arrangement-playback.mjs'
import { verifyPhraseSnapshot } from './phrase-arrangement.mjs'
import { midiSourcePattern } from './midi-source.mjs'
import { projectVstMidi } from './sequencer-vst.mjs'
import { sourceAudioClock, sourceAudioFrames } from './source-audio-clock.mjs'
import { readWaveMetadata } from './wave-file.mjs'
import { preparePractice } from './arrangement-practice.mjs'
import { renderBoundVst } from './project-sound-files.mjs'
import { nativeJob } from './vst.mjs'
import { preparePracticeVst, practiceAudioClock } from './practice-vst.mjs'

const digest = bytes => createHash('sha256').update(bytes).digest('hex')
const prepareBacking = {
  'prepare-wave': prepareArrangementWave, 'prepare-midi': prepareArrangementMidi,
  'prepare-mixed': prepareArrangementMixed, 'prepare-audio': prepareArrangementAudio,
  'prepare-capture': prepareArrangementCaptureRegions,
}

// Worker stage: snapshot sources and validate all external routing before the
// parent opens any plugin. Workers never own a native/plugin child.
export async function prepareVstSources(project, { route, sourceRoot, directory, signal } = {}) {
  signal?.throwIfAborted()
  const local = new Map(arrangementVstAssets(project, route).map(asset => [asset.id, asset]))
  if (!local.size) throw new Error('No audible local VST sources')
  const schedule = arrangementPlaybackSchedule(project), residual = {
    ...project, clips: project.clips.filter(clip => !local.has(clip.asset)),
  }
  delete residual.practice
  let backing = null
  if (schedule.some(clip => !local.has(clip.asset))) {
    const selection = arrangementPlaybackRequest(residual, route)
    if (!prepareBacking[selection.kind]) throw new Error('Invalid residual VST backing route')
    // The combined audio master consumes absolute MIDI regions, including a
    // loop which contains only MIDI among the residual sources.
    if (selection.kind === 'prepare-midi') delete residual.playbackLoop
    backing = await prepareBacking[selection.kind](residual, { ...selection, sourceRoot, directory, signal })
  }
  const renders = [], regions = []
  for (const clip of schedule) {
    const asset = local.get(clip.asset)
    if (!asset) continue
    signal?.throwIfAborted()
    const key = JSON.stringify([asset.id, clip.pattern ?? null])
    let render = renders.find(render => render.key === key)
    if (!render) {
      if (asset.kind === 'practice') render = { ...await preparePracticeVst(project, asset, { sourceRoot, directory, signal }), key }
      else {
        verifyPhraseSnapshot(asset)
        const performance = midiSourcePattern(asset.source, { pattern: clip.pattern })
        const { bytes } = projectVstMidi(asset.source, { pattern: clip.pattern })
        const id = randomUUID(), midiPath = join(directory, id + '.mid'), outputPath = join(directory, id + '.wav')
        await writeFile(midiPath, bytes, { flag: 'wx', mode: 0o600, signal })
        render = { key, id, sound: asset.source.sound, midiPath, outputPath, midiHash: digest(bytes),
          fullClock: sourceAudioClock(performance, 0, performance.ticks) }
      }
      renders.push(render)
    }
    const clock = asset.kind === 'practice' ? practiceAudioClock(asset, clip.offset, clip.extent)
      : sourceAudioClock(midiSourcePattern(asset.source, { pattern: clip.pattern }), clip.offset, clip.extent)
    regions.push({ id: clip.id, asset: render.id, startSeconds: project.playbackLoop
      ? clip.position / project.ppq * 60 / project.tempo : clip.startSeconds,
    sourceClock: clock, repeat: clip.repeat,
    ...(project.playbackLoop ? { projectTick: clip.position } : {}) })
  }
  signal?.throwIfAborted()
  return { backing, renders, regions }
}

// Worker stage: derived PCM is a private realization, never a saved WAV asset
// replacing the source's original MIDI bytes, tempo map, trim or copy clock.
export async function finishVstPlan(project, { preparation, rendered, directory, signal } = {}) {
  signal?.throwIfAborted()
  const backing = preparation.backing
  let plan = backing ? JSON.parse(await readFile(backing.path, { encoding: 'utf8', signal }))
    : { schemaVersion: 1, kind: 'wave-arrangement', duration: 0, assets: [], regions: [] }
  if (backing?.format === 'midi-arrangement') {
    plan = { schemaVersion: 2, kind: 'mixed-arrangement', duration: plan.duration, assets: [], regions: [], midi: plan }
  }
  if (rendered.length !== preparation.renders.length) throw new Error('Incomplete VST render set')
  let duration = plan.duration
  for (const source of preparation.renders) {
    signal?.throwIfAborted()
    const result = rendered.find(result => result.output_path === source.outputPath)
    const rate = source.kind === 'practice' ? source.sampleRate : 44100
    if (!result || (source.kind === 'practice' ? result.timeline_sha256 !== source.timelineHash : result.midi_sha256 !== source.midiHash) || result.preset_sha256 !== source.sound.preset.sha256
      || result.instrument?.identifier !== source.sound.instrument.identifier || result.instrument?.version !== source.sound.instrument.version
      || !Number.isSafeInteger(result.frames) || result.frames <= 0 || result.sample_rate !== rate) {
      throw new Error('VST render does not match the selected frozen source')
    }
    const full = sourceAudioFrames(source.fullClock, result.sample_rate)
    if (source.kind === 'practice' ? String(result.frames) !== source.frames : result.frames !== full.frameCount) throw new Error('VST render horizon differs from its original MIDI source')
    const metadata = await readWaveMetadata(source.outputPath, { frames: result.frames, channels: 2, sampleRate: result.sample_rate }, { signal })
    const hash = createHash('sha256')
    for await (const chunk of createReadStream(source.outputPath, { signal })) hash.update(chunk)
    const sha256 = hash.digest('hex')
    if (sha256 !== result.wav_sha256) throw new Error('VST audio changed before playback admission')
    plan.assets.push({ id: source.id, path: source.outputPath, sha256, ...metadata, frames: result.frames })
    for (const clip of preparation.regions.filter(clip => clip.asset === source.id)) {
      const frames = sourceAudioFrames(clip.sourceClock, metadata.sampleRate)
      plan.regions.push({ ...clip, ...frames })
      const clock = clip.sourceClock, d = BigInt(clock.denominator)
      const n = (BigInt(clock.end) - BigInt(clock.start)) * BigInt(clip.repeat) * BigInt(metadata.sampleRate)
      const total = n / d + (n % d ? 1n : 0n)
      duration = Math.max(duration, clip.startSeconds + Number(total) / metadata.sampleRate)
    }
  }
  const loop = arrangementLoop(project)
  if (loop) {
    duration = (project.playbackLoop.end - project.playbackLoop.start) / project.ppq * 60 / project.tempo
    plan.loop = { ...project.playbackLoop, ppq: project.ppq, tempo: project.tempo }
  } else {
    if (plan.midi) plan.midi.duration = duration
    if (plan.umpRegions) plan.umpRegions.duration = duration
  }
  if (!Number.isFinite(duration) || duration <= 0) throw new Error('VST arrangement has no representable duration')
  plan.duration = duration
  const path = join(directory, 'plan.json')
  await writeFile(path, JSON.stringify(plan), { flag: 'wx', mode: 0o600, signal })
  signal?.throwIfAborted()
  return preparePractice(project, { ...backing, path, duration, format: plan.kind,
    ...(loop ? { loop: true, originSeconds: loop.start } : {}) }, { signal })
}

// One parent-owned lease covers mkdir, both worker jobs, every plugin child,
// admission and playback. A successful plan retains this root until dispose;
// failure also releases it when no worker result ever existed.
export function startVstArrangement({ project, route, sourceRoot, directory, request, cancelRequest, run = nativeJob }) {
  const controller = new AbortController(), jobs = new Set(), children = new Set()
  let root, disposal
  const check = () => controller.signal.throwIfAborted()
  const remove = async () => { if (root) await rm(root, { recursive: true, force: true }) }
  const cancel = () => {
    controller.abort()
    for (const id of jobs) cancelRequest(id)
    for (const child of children) child.cancel()
  }
  const ask = async value => {
    check()
    let id
    const pending = request(value, issued => { id = issued; jobs.add(id) })
    // issued runs before postMessage: send cancellation only after request has
    // actually posted, preserving worker message order.
    if (controller.signal.aborted && id !== undefined) cancelRequest(id)
    try { const result = await pending; check(); return result }
    finally { jobs.delete(id) }
  }
  const promise = (async () => {
    try {
      root = await mkdtemp(join(directory, 'vst-play-')); check()
      const preparation = await ask({ kind: 'prepare-vst-sources', project, route, sourceRoot, directory: root })
      const rendered = []
      for (const source of preparation.renders) {
        check()
        const child = renderBoundVst(source.sound, { ...(source.kind === 'practice'
          ? { timeline_path: source.timelinePath, expected_timeline_sha256: source.timelineHash } : { midi_path: source.midiPath }), output_path: source.outputPath,
          sample_rate: source.sampleRate ?? 44100, tail_seconds: 0 }, { run })
        children.add(child)
        try { rendered.push(await child.promise); check() }
        finally { children.delete(child) }
      }
      return await ask({ kind: 'prepare-vst-plan', project, preparation, rendered, directory: root })
    } catch (error) {
      cancel()
      await Promise.allSettled([...children].map(child => child.promise))
      await remove()
      throw error
    }
  })()
  return { promise, cancel, dispose() {
    if (!disposal) disposal = (async () => { cancel(); await promise.catch(() => {}); await remove() })()
    return disposal
  } }
}
