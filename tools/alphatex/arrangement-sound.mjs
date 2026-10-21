import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises'
import { createReadStream } from 'node:fs'
import { join } from 'node:path'
import { createHash, randomUUID } from 'node:crypto'
import { arrangementPlaybackSchedule } from './arrangement.mjs'
import { arrangementLoop } from './arrangement-loop.mjs'
import { arrangementSoundAssets, arrangementPlaybackRequest, prepareArrangementWave, prepareArrangementMidi,
  prepareArrangementMixed, prepareArrangementAudio, prepareArrangementCaptureRegions } from './arrangement-playback.mjs'
import { verifyPhraseSnapshot } from './phrase-arrangement.mjs'
import { midiSourcePattern } from './midi-source.mjs'
import { projectVstMidi } from './sequencer-vst.mjs'
import { sourceAudioClock, sourceAudioFrames } from './source-audio-clock.mjs'
import { readWaveMetadata } from './wave-file.mjs'
import { preparePractice } from './arrangement-practice.mjs'
import { renderBoundVst } from './project-sound-files.mjs'
import { nativeJob } from './vst.mjs'
import { preparePracticeSound, practiceAudioClock } from './practice-sound.mjs'
import { fluidRenderPlan, isFluidSound, renderFluidSound } from './soundfont.mjs'

const digest = bytes => createHash('sha256').update(bytes).digest('hex')
const prepareBacking = {
  'prepare-wave': prepareArrangementWave, 'prepare-midi': prepareArrangementMidi,
  'prepare-mixed': prepareArrangementMixed, 'prepare-audio': prepareArrangementAudio,
  'prepare-capture': prepareArrangementCaptureRegions,
}

// Worker stage: snapshot sources and validate all external routing before the
// parent opens any plugin. Workers never own a native/plugin child.
export async function prepareSoundSources(project, { route, sourceRoot, directory, signal } = {}) {
  signal?.throwIfAborted()
  const local = new Map(arrangementSoundAssets(project, route).map(asset => [asset.id, asset]))
  if (!local.size) throw new Error('No audible local instrument sources')
  const schedule = arrangementPlaybackSchedule(project), residual = {
    ...project, clips: project.clips.filter(clip => !local.has(clip.asset)),
  }
  delete residual.practice
  let backing = null
  if (schedule.some(clip => !local.has(clip.asset))) {
    const selection = arrangementPlaybackRequest(residual, route)
    if (!prepareBacking[selection.kind]) throw new Error('Invalid residual instrument backing route')
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
      if (asset.kind === 'practice') render = { ...await preparePracticeSound(project, asset, { sourceRoot, directory, signal }), key }
      else {
        verifyPhraseSnapshot(asset)
        const performance = midiSourcePattern(asset.source, { pattern: clip.pattern })
        const id = randomUUID(), outputPath = join(directory, id + '.wav')
        const original = { key, id, sound: asset.source.sound, outputPath,
          fullClock: sourceAudioClock(performance, 0, performance.ticks) }
        if (isFluidSound(asset.source.sound)) {
          const bytes = Buffer.from(JSON.stringify(fluidRenderPlan(asset.source, { pattern: clip.pattern })))
          const planPath = join(directory, id + '.json')
          await writeFile(planPath, bytes, { flag: 'wx', mode: 0o400, signal })
          render = { ...original, kind: 'soundfont', planPath, planHash: digest(bytes) }
        } else {
          const { bytes } = projectVstMidi(asset.source, { pattern: clip.pattern }), midiPath = join(directory, id + '.mid')
          await writeFile(midiPath, bytes, { flag: 'wx', mode: 0o600, signal })
          render = { ...original, kind: 'vst', midiPath, midiHash: digest(bytes) }
        }
      }
      renders.push(render)
    }
    const clock = asset.kind === 'practice' ? practiceAudioClock(asset, clip.offset, clip.extent, clip.sourceDivisor)
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
export async function finishSoundPlan(project, { preparation, rendered, directory, signal } = {}) {
  signal?.throwIfAborted()
  const backing = preparation.backing
  let plan = backing ? JSON.parse(await readFile(backing.path, { encoding: 'utf8', signal }))
    : { schemaVersion: 1, kind: 'wave-arrangement', duration: 0, assets: [], regions: [] }
  if (backing?.format === 'midi-arrangement') {
    plan = { schemaVersion: 2, kind: 'mixed-arrangement', duration: plan.duration, assets: [], regions: [], midi: plan }
  }
  if (rendered.length !== preparation.renders.length) throw new Error('Incomplete instrument render set')
  let duration = plan.duration
  for (const [index, source] of preparation.renders.entries()) {
    signal?.throwIfAborted()
    if (!['soundfont', 'vst', 'practice'].includes(source.kind)) throw new Error('Unknown local instrument source')
    const row = rendered[index]
    if (row?.kind !== source.kind) throw new Error('Instrument render kind differs from its source')
    let outputPath, rate, frames, expectedHash, realization
    if (source.kind === 'soundfont') {
      const result = row.value.soundfont
      if (digest(await readFile(source.planPath, { signal })) !== source.planHash
        || row.value.path !== source.outputPath || result?.path !== source.outputPath || result.planSha256 !== source.planHash
        || result.fontSha256 !== source.sound.font.sha256 || result.engine?.kind !== 'fluidsynth'
        || result.engine.version !== source.sound.engine.version || result.engine.controlFrames !== source.sound.engine.controlFrames
        || result.bankStyle !== source.sound.bankStyle || result.channels !== 2 || result.sampleRate !== (source.sampleRate ?? 44100)) {
        throw new Error('SoundFont render differs from its frozen source plan')
      }
      outputPath = result.path; rate = result.sampleRate; frames = result.frames; expectedHash = result.wavSha256
      realization = { kind: 'soundfont', planSha256: source.planHash, fontSha256: result.fontSha256,
        engine: result.engine, bankStyle: result.bankStyle, timing: result.timing }
    } else {
      const result = row.value
      rate = source.kind === 'practice' ? source.sampleRate : 44100
      if (result?.output_path !== source.outputPath
        || (source.kind === 'practice' ? result.timeline_sha256 !== source.timelineHash : result.midi_sha256 !== source.midiHash)
        || result.preset_sha256 !== source.sound.preset.sha256 || result.instrument?.identifier !== source.sound.instrument.identifier
        || result.instrument?.version !== source.sound.instrument.version || result.sample_rate !== rate) {
        throw new Error('VST render does not match the selected frozen source')
      }
      outputPath = result.output_path; frames = result.frames; expectedHash = result.wav_sha256
    }
    const full = sourceAudioFrames(source.fullClock, rate)
    if (!Number.isSafeInteger(frames) || frames <= 0 || (source.frames !== undefined ? String(frames) !== source.frames : frames !== full.frameCount)) {
      throw new Error('Instrument render horizon differs from its original source')
    }
    const metadata = await readWaveMetadata(outputPath, { frames, channels: 2, sampleRate: rate }, { signal })
    const hash = createHash('sha256')
    for await (const chunk of createReadStream(outputPath, { signal })) hash.update(chunk)
    const sha256 = hash.digest('hex')
    if (sha256 !== expectedHash) throw new Error('Instrument audio changed before playback admission')
    plan.assets.push({ id: source.id, path: outputPath, sha256, ...metadata, frames, ...(realization ? { realization } : {}) })
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
  if (!Number.isFinite(duration) || duration <= 0) throw new Error('Instrument arrangement has no representable duration')
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
export function startSoundArrangement({ project, route, sourceRoot, directory, request, cancelRequest, run = nativeJob, runSoundfont }) {
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
      root = await mkdtemp(join(directory, 'sound-play-')); check()
      const preparation = await ask({ kind: 'prepare-sound-sources', project, route, sourceRoot, directory: root })
      const rendered = []
      for (const source of preparation.renders) {
        check()
        if (!['soundfont', 'vst', 'practice'].includes(source.kind)) throw new Error('Unknown local instrument source')
        const child = source.kind === 'soundfont' ? renderFluidSound(source.sound, {
          preparation: { promise: Promise.resolve({ path: source.planPath, sha256: source.planHash }),
            cancel: new Int32Array(new SharedArrayBuffer(4)) }, outputPath: source.outputPath, run: runSoundfont,
        }) : renderBoundVst(source.sound, { ...(source.kind === 'practice'
          ? { timeline_path: source.timelinePath, expected_timeline_sha256: source.timelineHash } : { midi_path: source.midiPath }), output_path: source.outputPath,
          sample_rate: source.sampleRate ?? 44100, tail_seconds: 0 }, { run })
        children.add(child)
        try { rendered.push({ kind: source.kind, value: await child.promise }); check() }
        finally { children.delete(child) }
      }
      return await ask({ kind: 'prepare-sound-plan', project, preparation, rendered, directory: root })
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
