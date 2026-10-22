import { spawn } from 'node:child_process'
import { mkdtemp, readFile, writeFile, rm, link, open } from 'node:fs/promises'
import { join, dirname, resolve } from 'node:path'
import { createReadStream, createWriteStream } from 'node:fs'
import { pipeline } from 'node:stream/promises'
import { arrangementPlaybackSchedule } from './arrangement.mjs'
import { prepareArrangementAudio } from './arrangement-playback.mjs'
import { prepareArrangementVst } from './arrangement-vst.mjs'
import { prepareArrangementSound } from './arrangement-sound.mjs'
import { isFluidSound } from './soundfont.mjs'
import { arrangementTransportPath } from './playback.mjs'
import { readWaveMetadata } from './wave-file.mjs'
import { projectNanoseconds, rational } from './exact-time.mjs'

// Export the complete authored arrangement once. Playback loops, practice
// clicks and the live output route do not change the exported document.
export function arrangementWaveProject(project) {
  const { playbackLoop, practice, ...linear } = project
  const schedule = arrangementPlaybackSchedule(linear)
  if (!schedule.length) throw new Error('No audible arrangement regions to export')
  for (const clip of schedule) {
    const asset = linear.assets.find(asset => asset.id === clip.asset)
    if (asset.kind === 'capture' && clip.component !== 'audio' && BigInt(asset.manifest.midiPacketCount) > 0n) {
      throw new Error('Captured MIDI needs a recorded instrument return for WAV export; split the take and mute its MIDI component to export the recorded audio')
    }
  }
  return linear
}

export async function renderArrangementWave(plan, path, { signal, executable = arrangementTransportPath } = {}) {
  signal?.throwIfAborted()
  const child = spawn(executable, ['render', '--file', plan, '--output', path], { stdio: ['ignore', 'pipe', 'pipe'] })
  let output = '', diagnostic = '', failure
  child.stdout.setEncoding('utf8').on('data', text => { output += text })
  child.stderr.setEncoding('utf8').on('data', text => { diagnostic += text })
  const abort = () => child.kill('SIGTERM')
  signal?.addEventListener('abort', abort, { once: true })
  if (signal?.aborted) abort()
  try {
    await new Promise((yes, no) => {
      child.once('error', error => { failure = error })
      child.once('close', (code, exitSignal) => {
        if (signal?.aborted) no(signal.reason)
        else if (failure) no(failure)
        else if (code !== 0) no(new Error(diagnostic || `WAV export ended: ${code ?? exitSignal}`))
        else yes()
      })
    })
    const receipt = JSON.parse(output)
    if (receipt.kind !== 'rendered' || receipt.path !== path || receipt.sampleRate !== 44100
        || !Number.isSafeInteger(receipt.frames) || receipt.frames <= 0
        || !Number.isSafeInteger(receipt.channels) || receipt.channels <= 0
        || !Number.isFinite(receipt.peak) || receipt.peak < 0) throw new Error('Invalid native WAV export receipt')
    await readWaveMetadata(path, { sampleRate: receipt.sampleRate, channels: receipt.channels, frames: receipt.frames }, { signal })
    return receipt
  } finally { signal?.removeEventListener('abort', abort) }
}

// Publication is one no-replace link after a complete, synced private copy.
// Cancellation joins the renderer first; cleanup never removes an old target.
export async function exportArrangementWave(project, target, { sourceRoot, directory, signal,
  onProgress, prepareAudio = prepareArrangementAudio, prepareVst = prepareArrangementVst,
  prepareSound = prepareArrangementSound,
  render = renderArrangementWave } = {}) {
  signal?.throwIfAborted()
  const selected = arrangementWaveProject(project), path = resolve(target)
  const temporary = await mkdtemp(join(directory, 'wave-export-'))
  let publication
  try {
    const schedule = arrangementPlaybackSchedule(selected), audible = new Set(schedule.map(clip => clip.id))
    const kinds = new Map(selected.assets.map(asset => [asset.id, asset.kind !== 'midi' ? 'audio'
      : isFluidSound(asset.source.sound) ? 'soundfont' : 'vst']))
    const part = kind => ({ ...selected, clips: selected.clips.filter(clip => audible.has(clip.id) && kinds.get(clip.asset) === kind) })
    const plans = []
    for (const [kind, prepare, progress] of [['audio', prepareAudio, 'wave-snapshot'],
      ['vst', prepareVst, 'vst-projection'], ['soundfont', prepareSound, null]]) {
      const project = part(kind)
      if (!project.clips.length) continue
      if (kind !== 'soundfont') onProgress?.({ kind: progress })
      const prepared = await prepare(project, { sourceRoot, directory: temporary, signal, onProgress })
      const plan = JSON.parse(await readFile(prepared.path, { encoding: 'utf8', signal }))
      const placements = new Map(arrangementPlaybackSchedule(project).map(clip => [clip.id, clip]))
      plan.regions = plan.regions.map(region => {
        let frame = 0n
        if (kind !== 'vst') {
          const clip = placements.get(region.id)
          if (!clip) throw new Error('WAV export region lost its authored placement')
          const [n, d] = clip.startNanoseconds ? rational(clip.startNanoseconds) : projectNanoseconds(project, clip.position)
          frame = n * 44100n / (d * 1_000_000_000n)
        }
        if (frame < 0n || frame > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('WAV export placement exceeds exact frame precision')
        return { ...region, exportStartFrame: Number(frame) }
      })
      plans.push(plan)
    }
    const combined = { schemaVersion: 4, kind: 'capture-audio-arrangement',
      duration: Math.max(...plans.map(plan => plan.duration)),
      assets: plans.flatMap(plan => plan.assets), regions: plans.flatMap(plan => plan.regions) }
    const plan = join(temporary, 'export.json'), audio = join(temporary, 'export.wav')
    await writeFile(plan, JSON.stringify(combined), { flag: 'wx', mode: 0o600, signal })
    onProgress?.({ kind: 'wave-mix' })
    const receipt = await render(plan, audio, { signal })
    signal?.throwIfAborted()
    publication = await mkdtemp(join(dirname(path), '.masc-wave-export-'))
    const staged = join(publication, 'audio.wav')
    await pipeline(createReadStream(audio), createWriteStream(staged, { flags: 'wx', mode: 0o600 }), { signal })
    const file = await open(staged, 'r')
    try { await file.sync() } finally { await file.close() }
    signal?.throwIfAborted()
    await link(staged, path)
    return { ...receipt, path }
  } finally {
    if (publication) await rm(publication, { recursive: true, force: true })
    await rm(temporary, { recursive: true, force: true })
  }
}
