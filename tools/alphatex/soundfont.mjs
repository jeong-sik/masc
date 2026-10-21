import { readFile, writeFile, mkdtemp, rm, link } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { nativeJob } from './vst.mjs'
import { validateSound } from './project-sound.mjs'
import { importMidiSource, midiSourcePattern } from './midi-source.mjs'
import { projectMidi } from './sequencer-files.mjs'
import { sourceAudioClock, sourceAudioFrames, sourceAudioEventFrames } from './source-audio-clock.mjs'
import { sourceLoopWindow } from './midi-source-playback.mjs'
import { readWaveMetadata } from './wave-file.mjs'

const digest = bytes => createHash('sha256').update(bytes).digest('hex')
const host = fileURLToPath(new URL('./soundfont_host.py', import.meta.url))
const runHost = request => nativeJob(request, { command: 'python3', args: [host], label: 'SoundFont' })
export const isFluidSound = sound => sound?.kind === 'soundfont' && sound.engine?.kind === 'fluidsynth'

export function captureFluidSound(path, { run = runHost } = {}) {
  let cancelled = false, child
  const check = () => { if (cancelled) throw new DOMException('SoundFont selection cancelled', 'AbortError') }
  const promise = (async () => {
    const file = path ?? fileURLToPath(import.meta.resolve('@coderline/alphatab/soundfont/sonivox.sf2'))
    const bytes = await readFile(file); check()
    child = run({ operation: 'inspect' })
    const engine = await child.promise; check()
    return validateSound({ kind: 'soundfont', engine: { kind: 'fluidsynth', version: engine.version, controlFrames: engine.controlFrames },
      bankStyle: 'mma', font: { name: basename(file), data: bytes.toString('base64'), sha256: digest(bytes) } })
  })()
  return { promise, cancel() { cancelled = true; child?.cancel() } }
}

// Worker-only preparation: the original performance owns timing/order/ports.
// No note-only phrase reconstruction, SMF file-player or device output is used.
export function fluidRenderPlan(project, options = {}) {
  const performance = midiSourcePattern(project.kind === 'midi-source' ? project : importMidiSource(projectMidi(project, options)), options)
  const clock = sourceAudioClock(performance, 0, performance.ticks), sampleRate = 44100
  const frames = sourceAudioFrames(clock, sampleRate).frameCount, ports = new Map()
  for (const { event, frame } of sourceAudioEventFrames(performance, sampleRate)) {
    if (event.kind === 'meta') continue
    // A complete F0 message is an engine request; fragmented/escape/system
    // streams need an explicit capable owner, never a silent discard.
    const bytes = event.kind === 'channel' ? event.bytes
      : event.status === 0xf0 ? [0xf0, ...event.data] : [0xf7, ...event.data]
    const stream = ports.get(event.port) ?? []
    stream.push({ frame, bytes }); ports.set(event.port, stream)
  }
  return { schemaVersion: 1, kind: 'soundfont-render', sampleRate, frames,
    ports: [...ports].map(([port, events]) => ({ port, events })),
    ...(project.kind === 'midi-source' && options.loop ? { sourceWindow: sourceLoopWindow(performance, options.sourceLoop) } : {}) }
}

// Parent-owned frozen font, native child and result admission. The successful
// output belongs to the caller's private directory; disposal never removes it.
export function renderFluidSound(sound, { preparation, outputPath, run = runHost }) {
  validateSound(sound)
  if (!isFluidSound(sound)) throw new Error('Select the FluidSynth SoundFont engine')
  let cancelled = false, child, root, sealed = false
  const check = () => { if (cancelled) throw new DOMException('SoundFont rendering cancelled', 'AbortError') }
  const promise = (async () => {
    try {
      const prepared = await preparation.promise; check()
      const bytes = await readFile(prepared.path); check()
      if (digest(bytes) !== prepared.sha256) throw new Error('SoundFont source plan changed before native admission')
      const plan = JSON.parse(bytes.toString('utf8'))
      const frameRange = plan.sourceWindow ? sourceAudioFrames(plan.sourceWindow.clock, plan.sampleRate) : null
      if (frameRange && (frameRange.frameCount <= 0 || frameRange.offsetFrames + frameRange.frameCount > plan.frames)) {
        throw new Error('Selected source loop has no complete SoundFont PCM window')
      }
      root = await mkdtemp(join(dirname(outputPath), 'soundfont-')); check()
      const path = join(root, 'bound.sf2'), renderedPath = join(root, 'render.wav')
      await writeFile(path, Buffer.from(sound.font.data, 'base64'), { flag: 'wx', mode: 0o400 }); check()
      child = run({ operation: 'render', plan: { ...plan, engine: sound.engine, bankStyle: sound.bankStyle,
        font: { path, sha256: sound.font.sha256 }, output: renderedPath } })
      const result = await child.promise; check()
      if (result.path !== renderedPath || result.fontSha256 !== sound.font.sha256 || result.engine?.kind !== 'fluidsynth'
        || result.engine.version !== sound.engine.version || result.frames !== plan.frames || result.sampleRate !== plan.sampleRate
        || result.engine.controlFrames !== sound.engine.controlFrames
        || result.channels !== 2 || result.bankStyle !== sound.bankStyle || !Number.isFinite(result.peak)
        || JSON.stringify(result.ports) !== JSON.stringify(plan.ports.map(port => port.port).sort((a, b) => a - b))
        || result.events !== plan.ports.reduce((count, port) => count + port.events.length, 0)) throw new Error('SoundFont receipt differs from its bound source')
      const quantum = sound.engine.controlFrames, timing = { kind: 'control-block-ceil', quantumFrames: quantum,
        changedEvents: 0, maxDelayFrames: 0, terminalEvents: 0, events: [] }
      for (const port of plan.ports) for (const event of port.events) {
        if (event.frame === plan.frames) timing.terminalEvents++
        else { const delay = Math.ceil(event.frame / quantum) * quantum - event.frame
          timing.changedEvents += Number(delay !== 0); timing.maxDelayFrames = Math.max(timing.maxDelayFrames, delay) }
        timing.events.push([port.port, event.frame, event.frame === plan.frames ? null : Math.ceil(event.frame / quantum) * quantum])
      }
      if (JSON.stringify(result.timing) !== JSON.stringify(timing)) throw new Error('SoundFont timing receipt differs from its control quantum')
      const metadata = await readWaveMetadata(renderedPath, { frames: plan.frames, channels: 2, sampleRate: plan.sampleRate }); check()
      if (metadata.encoding !== 'float' || metadata.bitsPerSample !== 32
        || digest(await readFile(renderedPath)) !== result.wavSha256) throw new Error('SoundFont output differs from its receipt')
      check()
      // Native output is private and fully checked. Seal synchronously before
      // the non-cancellable exclusive publication. Later stop still prevents
      // playback through the TUI generation; it does not undo a sealed file.
      sealed = true
      await link(renderedPath, outputPath)
      return { path: outputPath, duration: plan.frames / plan.sampleRate, clippedSamples: 0, format: 'wav', soundfont: { ...result, path: outputPath, planSha256: prepared.sha256 },
        ...(plan.sourceWindow ? { sourceWindow: plan.sourceWindow,
          frameRange } : {}) }
    } finally { if (root) await rm(root, { recursive: true, force: true }) }
  })()
  return { promise, cancel() {
    if (sealed) return false
    cancelled = true; Atomics.store(preparation.cancel, 0, 1); child?.cancel(); return true
  } }
}
