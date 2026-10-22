import { spawn } from 'node:child_process'
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'
import { join, resolve } from 'node:path'
import { arrangementPlaybackSchedule } from './arrangement.mjs'
import { arrangementLoop, loopMidiRegions } from './arrangement-loop.mjs'
import { binary, regionEdgeSeconds } from './exact-time.mjs'
import { midiSourcePattern } from './midi-source.mjs'
import { verifyPhraseSnapshot } from './phrase-arrangement.mjs'
import { validateSound } from './project-sound.mjs'
import { midiTransportPath } from './playback.mjs'
import { nativeJob } from './vst.mjs'
import { renderBoundVst } from './project-sound-files.mjs'
import { readWaveMetadata } from './wave-file.mjs'

const sampleRate = 44100
function pcmFrame(seconds, roundUp) {
  let n = 0n, d = 1n
  for (const value of seconds) {
    if (value === 0) continue
    const [vn, vd] = binary(value)
    n = n * vd + vn * d; d *= vd
  }
  n *= BigInt(sampleRate)
  const result = Number(n / d + (roundUp && n % d ? 1n : 0n))
  if (!Number.isSafeInteger(result)) throw new Error('VST arrangement exceeds exact PCM frame precision')
  return result
}

// The projector never opens MIDI destinations or plug-ins. Bound VST sound is
// carried separately to the renderer; wire ports retain their source identity.
export function arrangementVstMidiPlan(project) {
  const schedule = arrangementPlaybackSchedule(project)
  const byID = new Map(project.assets.map(asset => [asset.id, asset]))
  const clips = schedule.filter(clip => byID.get(clip.asset).kind === 'midi')
  if (!clips.length) throw new Error('No audible MIDI regions to render through VST')
  const sources = [], sounds = [], regions = []
  for (const clip of clips) {
    const asset = byID.get(clip.asset), id = JSON.stringify([asset.id, clip.pattern ?? null])
    if (!sources.some(source => source.id === id)) {
      verifyPhraseSnapshot(asset)
      if (asset.source.sound === undefined) throw new Error(`Choose a VST sound for MIDI asset ${asset.id}`)
      const sound = validateSound(asset.source.sound)
      if (sound.kind !== 'vst') throw new Error(`Choose a VST sound for MIDI asset ${asset.id}`)
      const performance = midiSourcePattern(asset.source, { pattern: clip.pattern })
      const events = performance.events.flatMap(event => {
        if (event.kind === 'meta') return []
        const bytes = event.kind === 'channel' ? event.bytes
          : event.status === 0xf0 ? [0xf0, ...event.data] : event.data
        return bytes.length ? [{ seconds: event.seconds, port: event.port, bytes: [...bytes] }] : []
      })
      sources.push({ id, duration: performance.seconds, events })
      sounds.push({ source: id, sound })
    }
    regions.push({ id: clip.id, source: id, startSeconds: clip.startSeconds,
      sourceStart: clip.sourceStartSeconds, sourceEnd: clip.sourceEndSeconds, repeatCount: clip.repeat,
      startNanoseconds: clip.startNanoseconds, periodNanoseconds: clip.periodNanoseconds })
  }
  const loop = arrangementLoop(project), selected = loopMidiRegions(regions, loop)
  const used = new Set(selected.map(region => region.source))
  const duration = loop ? selected.reduce((end, region) => Math.max(end,
    regionEdgeSeconds(region.startNanoseconds, region.periodNanoseconds, region.repeatCount)), loop.duration)
    : schedule.reduce((end, clip) => Math.max(end, clip.endSeconds), 0)
  if (!Number.isFinite(duration) || duration <= 0) throw new Error('VST arrangement has no representable duration')
  return { plan: { schemaVersion: 1, kind: 'vst-arrangement', duration,
    sources: sources.filter(source => used.has(source.id)), regions: selected },
  sounds: sounds.filter(sound => used.has(sound.source)),
  ...(loop ? { loop: true, originSeconds: loop.start } : {}) }
}

// Cancellation waits for child close, not merely for a signal or a reply. Only
// the caller removes the encompassing preparation tree after that boundary.
export async function prepareArrangementVstMidi(project, { directory, signal, executable = midiTransportPath } = {}) {
  signal?.throwIfAborted()
  const selected = arrangementVstMidiPlan(project), root = resolve(directory)
  const path = join(root, 'vst-midi.json'), output = join(root, 'vst-midi-parts')
  await writeFile(path, JSON.stringify(selected.plan), { flag: 'wx', mode: 0o600, signal })
  signal?.throwIfAborted()
  const child = spawn(executable, ['export-vst', '--file', path, '--output', output], { stdio: ['ignore', 'ignore', 'pipe'] })
  let failure = null, diagnostic = '', cancelled = false
  child.stderr.setEncoding('utf8').on('data', text => { diagnostic += text })
  const abort = () => { cancelled = true; child.kill('SIGTERM') }
  signal?.addEventListener('abort', abort, { once: true })
  if (signal?.aborted) abort()
  try {
    await new Promise((yes, no) => {
      child.once('error', error => { failure = error })
      child.once('close', (code, exitSignal) => {
        if (cancelled) no(signal.reason)
        else if (failure) no(failure)
        else if (code !== 0) no(new Error(diagnostic || `VST MIDI preparation ended: ${code ?? exitSignal}`))
        else yes()
      })
    })
  } finally { signal?.removeEventListener('abort', abort) }
  signal?.throwIfAborted()
  const manifest = JSON.parse(await readFile(join(output, 'manifest.json'), { encoding: 'utf8', signal }))
  if (manifest?.schemaVersion !== 1 || manifest.kind !== 'vst-render-parts'
      || manifest.duration !== selected.plan.duration || !Array.isArray(manifest.parts) || !manifest.parts.length) {
    throw new Error('Invalid native VST MIDI preparation receipt')
  }
  const identities = new Set()
  const expected = new Map()
  for (const region of selected.plan.regions) {
    const source = selected.plan.sources.find(source => source.id === region.source)
    const ports = new Set(source.events.filter(event => event.seconds < region.sourceEnd
      || event.seconds === region.sourceEnd && region.sourceEnd === source.duration).map(event => event.port))
    for (const port of ports) expected.set(JSON.stringify([region.id, port]), region)
  }
  if (manifest.parts.length !== expected.size) throw new Error('Native VST preparation omitted or added a region/port instance')
  const parts = manifest.parts.map((part, index) => {
    const identity = JSON.stringify([part.region, part.port]), region = expected.get(identity)
    const sound = selected.sounds.find(value => value.source === part.source)?.sound
    if (!region || region.source !== part.source || !sound || part.id !== index
        || part.path !== join(output, `part-${index}.jsonl`) || identities.has(identity)
        || !Number.isInteger(part.port) || part.port < 0 || part.port > 127
        || !Number.isFinite(part.startSeconds) || part.startSeconds < 0
        || !Number.isFinite(part.duration) || part.duration <= 0
        || part.startSeconds !== regionEdgeSeconds(region.startNanoseconds, region.periodNanoseconds, 0)
        || part.duration !== regionEdgeSeconds(region.startNanoseconds, region.periodNanoseconds, region.repeatCount) - part.startSeconds
        || !Number.isSafeInteger(part.eventCount) || part.eventCount < 0
        || typeof part.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(part.sha256)) {
      throw new Error('Invalid native VST region/port ownership receipt')
    }
    identities.add(identity)
    return { ...part, sound }
  })
  return { ...selected, parts, path: join(output, 'manifest.json') }
}

// Each source port/region owns a fresh native instance. Render one at a time,
// then sum their float WAVs on the common sample grid. MIDI prefix chasing is
// performed before synthesis, rather than by trimming already rendered audio.
export async function prepareArrangementVst(project, { directory, signal, executable = midiTransportPath, run = nativeJob } = {}) {
  signal?.throwIfAborted()
  const temporary = await mkdtemp(join(directory, 'vst-play-'))
  let job = null
  const abort = () => job?.cancel()
  signal?.addEventListener('abort', abort)
  const wait = async owned => {
    job = owned
    if (signal?.aborted) abort()
    try { const result = await owned.promise; signal?.throwIfAborted(); return result }
    finally { if (job === owned) job = null }
  }
  try {
    const selected = await prepareArrangementVstMidi(project, { directory: temporary, signal, executable })
    const tail = selected.loop ? 0 : 1, rendered = []
    for (const part of selected.parts) {
      signal?.throwIfAborted()
      const path = join(temporary, `instance-${part.id}.wav`)
      const result = await wait(renderBoundVst(part.sound, { timeline_path: part.path, timeline_duration: part.duration,
        timeline_sha256: part.sha256, timeline_event_count: part.eventCount, output_path: path,
        sample_rate: sampleRate, tail_seconds: tail, origin_seconds: part.startSeconds }, { run }))
      if (result.output_path !== path || result.sample_rate !== sampleRate
          || result.frame_origin !== pcmFrame([part.startSeconds], false)
          || result.frames !== pcmFrame([part.startSeconds, part.duration, tail], true) - result.frame_origin
          || result.timeline_sha256 !== part.sha256 || result.timeline_event_count !== part.eventCount
          || !Number.isFinite(result.peak) || result.peak < 0) throw new Error('VST instance receipt differs from its admitted region')
      rendered.push(result)
    }
    signal?.throwIfAborted()
    const audioPath = join(temporary, 'backing.wav'), frames = pcmFrame([selected.plan.duration, tail], true)
    const mixed = await wait(run({ operation: 'mix', parts: rendered, output_path: audioPath, sample_rate: sampleRate, frames }))
    if (mixed.output_path !== audioPath || mixed.sample_rate !== sampleRate || mixed.frames !== frames
        || mixed.instances !== rendered.length || !Number.isFinite(mixed.peak) || mixed.peak < 0) throw new Error('VST mix receipt differs from its admitted PCM clock')
    if (mixed.peak === 0) throw new Error('Selected VST instruments produced silence; check their presets, sample libraries, and licenses')
    const metadata = await readWaveMetadata(audioPath, { channels: 2, sampleRate, frames }, { signal })
    const id = randomUUID(), loop = arrangementLoop(project)
    const plan = { schemaVersion: 1, kind: 'wave-arrangement', duration: loop ? loop.duration : frames / sampleRate,
      assets: [{ id, path: audioPath, sha256: mixed.wav_sha256, ...metadata, frames }],
      regions: [{ id: randomUUID(), asset: id, startSeconds: loop ? loop.start : 0,
        offsetFrames: 0, frameCount: frames, repeat: 1, ...(loop ? { projectTick: project.playbackLoop.start } : {}) }],
      ...(loop ? { loop: { ...project.playbackLoop, ppq: project.ppq, tempo: project.tempo } } : {}) }
    const path = join(temporary, 'plan.json')
    await writeFile(join(temporary, 'render.json'), JSON.stringify({ projection: selected.path, instances: rendered, mix: mixed }), { flag: 'wx', mode: 0o600, signal })
    await writeFile(path, JSON.stringify(plan, (_, value) => typeof value === 'bigint' ? String(value) : value), { flag: 'wx', mode: 0o600, signal })
    signal?.throwIfAborted()
    return { path, duration: plan.duration, format: 'wave-arrangement', ...(loop ? { loop: true, originSeconds: loop.start } : {}) }
  } catch (error) { await rm(temporary, { recursive: true, force: true }); throw error }
  finally { signal?.removeEventListener('abort', abort) }
}
