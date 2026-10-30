import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { createHash } from 'node:crypto'
import { setImmediate } from 'node:timers/promises'
import { devices, record } from './capture.mjs'
import { openPlayback } from './playback.mjs'
import { readCapture } from './session-data.mjs'
import { readWaveMetadata } from './wave-file.mjs'

const hash = bytes => createHash('sha256').update(bytes).digest('hex')
const unsigned = value => {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value) || BigInt(value) > 0xffffffffffffffffn) throw new Error('Invalid calibration host clock')
  return BigInt(value)
}
export function calibrationSelection({ output, inputChannel, outputChannel, maxLagMs }) {
  if (typeof output !== 'string' || !output || ![inputChannel, outputChannel].every(n => Number.isSafeInteger(n) && n > 0)
      || !Number.isFinite(maxLagMs) || maxLagMs <= 0) throw new Error('Choose output UID, 1-based input/output channels and a positive search span in milliseconds')
  return { output, inputChannel, outputChannel, maxLagMs }
}
// These lengths define the emitted experiment, not a timeout or an acceptance
// threshold. A quiet 20 ms windowed chirp is repeated in disjoint search spans.
export function calibrationReference(sampleRate, channels, selection) {
  calibrationSelection(selection)
  if (![sampleRate, channels].every(n => Number.isSafeInteger(n) && n > 0) || selection.outputChannel > channels) throw new Error('Unavailable calibration sample rate or output channel')
  const length = Math.max(2, Math.ceil(sampleRate * .02)), guard = Math.ceil(sampleRate * .05)
  const radius = Math.ceil(sampleRate * selection.maxLagMs / 1000)
  const pulseFrames = [guard + radius, guard + 3 * radius + length]
  const frames = pulseFrames[1] + radius + length + guard
  const size = frames * channels * 4
  if (!Number.isSafeInteger(size) || size + 36 > 0xffffffff || sampleRate * channels * 4 > 0xffffffff) throw new Error('Calibration experiment exceeds RIFF size bounds')
  const probe = Float32Array.from({ length }, (_, i) => {
    const t = i / length
    return .125 * Math.sin(Math.PI * t) ** 2 * Math.sin(2 * Math.PI * (i / 64 + i * i * (1 / 8 - 1 / 64) / (2 * length)))
  })
  const wave = Buffer.alloc(44 + size)
  wave.write('RIFF'); wave.writeUInt32LE(36 + size, 4); wave.write('WAVEfmt ', 8); wave.writeUInt32LE(16, 16)
  wave.writeUInt16LE(3, 20); wave.writeUInt16LE(channels, 22); wave.writeUInt32LE(sampleRate, 24)
  wave.writeUInt32LE(sampleRate * channels * 4, 28); wave.writeUInt16LE(channels * 4, 32); wave.writeUInt16LE(32, 34)
  wave.write('data', 36); wave.writeUInt32LE(size, 40)
  for (const frame of pulseFrames) for (let i = 0; i < probe.length; i++) wave.writeFloatLE(probe[i], 44 + ((frame + i) * channels + selection.outputChannel - 1) * 4)
  return { wave, probe, pulseFrames, frames, sampleRate, channels, radius }
}

// Residual is captured sample host time minus the scheduled output sample host
// time. It can be negative: device presentation compensation is already present
// in these clocks. It is not an unqualified physical roundtrip measurement.
export async function analyzeCalibration({ directory, reference, playback, selection, signal }) {
  signal?.throwIfAborted()
  const timeline = await readCapture(join(directory, 'capture'), { signal }), manifest = timeline.manifest, clock = manifest.clock
  const epoch = playback.clock, rate = manifest.sampleRate
  if (manifest.state !== 'recorded' || rate !== reference.sampleRate || selection.inputChannel > manifest.channels
      || epoch?.kind !== 'mach-host-time' || epoch.position !== 0 || epoch.numer !== clock.numer || epoch.denom !== clock.denom
      || !Number.isSafeInteger(clock.numer) || clock.numer <= 0 || !Number.isSafeInteger(clock.denom) || clock.denom <= 0
      || !Number.isFinite(epoch.sampleRate) || epoch.sampleRate <= 0 || playback.device?.id !== selection.output) throw new Error('Calibration source clock or selected device changed')
  const anchor = unsigned(epoch.anchor), n = BigInt(clock.numer), d = BigInt(clock.denom), r = BigInt(rate)
  const path = join(directory, 'capture', 'audio.wav'), metadata = await readWaveMetadata(path, { sampleRate: rate, channels: manifest.channels, frames: manifest.audioFrames }, { signal })
  if (metadata.encoding !== 'float' || metadata.bitsPerSample !== 32) throw new Error('Calibration requires native float32 capture')
  const bytes = await readFile(path, { signal }), samples = new Float32Array(Number(metadata.frames)), energy = new Float64Array(samples.length + 1)
  for (let i = 0; i < samples.length; i++) {
    const value = bytes.readFloatLE(metadata.dataOffset + i * metadata.blockAlign + (selection.inputChannel - 1) * 4)
    if (!Number.isFinite(value)) throw new Error('Nonfinite calibration audio')
    samples[i] = value; energy[i + 1] = energy[i] + value * value
  }
  const probe = reference.probe, probePower = probe.reduce((sum, x) => sum + x * x, 0), matches = []
  for (const pulse of reference.pulseFrames) {
    let best = null
    for (const block of timeline.audio) {
      signal?.throwIfAborted()
      const blockHost = unsigned(block.hostTime), offset = Number(block.offset)
      // Subtract the UInt64 clocks before converting the short local interval.
      const expected = Number((anchor - blockHost) * n) / Number(d) / 1e9 * rate + pulse
      const first = Math.max(0, Math.ceil(expected - reference.radius)), after = Math.min(block.frames, Math.floor(expected + reference.radius) + 1)
      for (let local = first; local < after; local++) {
        const index = offset + local
        if (index + probe.length > samples.length) continue
        const power = energy[index + probe.length] - energy[index]
        if (!(power > 0)) continue
        let dot = 0
        for (let j = 0; j < probe.length; j++) dot += samples[index + j] * probe[j]
        const correlation = Math.max(-1, Math.min(1, dot / Math.sqrt(power * probePower)))
        if (!best || Math.abs(correlation) > Math.abs(best.correlation)) {
          const numerator = (blockHost - anchor) * n * r + BigInt(local - pulse) * 1_000_000_000n * d
          const denominator = d * r
          best = { frame: index, blockHostTime: block.hostTime, blockFrameOffset: String(block.offset), localFrame: local, correlation,
            residualNanoseconds: { numerator: String(numerator), denominator: String(denominator) },
            residualMs: Number(numerator) / Number(denominator) / 1e6 }
        }
      }
      // Analysis lives in the IO worker; yield at recorded block boundaries so
      // cancellation can drain an experiment even during its matched filter.
      await setImmediate(undefined, { signal })
    }
    if (!best) throw new Error('No non-silent calibration candidate in the selected search span')
    matches.push(best)
  }
  return { schemaVersion: 1, kind: 'audio-calibration-candidate', status: 'unapplied',
    input: manifest.input, output: playback.device, inputChannel: selection.inputChannel, outputChannel: selection.outputChannel,
    inputSampleRate: rate, outputSampleRate: epoch.sampleRate, maxLagMs: selection.maxLagMs,
    sampleResolutionMs: 1000 / rate, pulseSpreadMs: Math.max(...matches.map(m => m.residualMs)) - Math.min(...matches.map(m => m.residualMs)),
    matches, playback, captureClock: clock, reference: { file: 'reference.wav', sha256: hash(reference.wave), pulseFrames: reference.pulseFrames, probeFrames: probe.length },
    capturedWave: { file: 'capture/audio.wav', sha256: hash(bytes), frames: manifest.audioFrames },
    meaning: 'Candidate residual from scheduled playback host clock to captured sample host clock. Inspect both correlations and spread; no automatic compensation, physical/acoustic roundtrip or sub-sample precision claim.' }
}

export async function measureAudioCalibration({ input, output, inputChannel, outputChannel, maxLagMs, directory, signal, analyze = analyzeCalibration }) {
  const selection = calibrationSelection({ output, inputChannel, outputChannel, maxLagMs })
  if (typeof input !== 'string' || !input) throw new Error('Choose an audio input UID')
  signal?.throwIfAborted()
  await mkdir(directory, { mode: 0o700 })
  let capture, player, captureFailure, closingCapture = false
  const abort = () => { capture?.stop(); player?.terminate() }
  signal?.addEventListener('abort', abort, { once: true })
  try {
    const found = await devices({ audioOnly: true, signal }), source = found.audio.find(d => d.id === input), destination = found.audio.find(d => d.id === output)
    if (!source || inputChannel > source.inputs || !destination || outputChannel > destination.outputs) throw new Error('Selected audio loopback channels are unavailable')
    signal?.throwIfAborted()
    let ready, refuse
    const firstAudio = new Promise((resolve, reject) => { ready = resolve; refuse = reject }); firstAudio.catch(() => {})
    let header
    capture = record({ input, midi: 'none', directory: join(directory, 'capture'), onEvent(event) {
      if (event.kind === 'recording') header = event
      if (event.kind === 'audio') ready()
      if (event.kind === 'error') refuse(new Error(event.message))
    } })
    const captureFailed = error => { captureFailure = error; refuse(error); player?.terminate() }
    capture.completion.then(() => { if (!closingCapture) captureFailed(new Error('Calibration capture ended before playback completed')) }, captureFailed)
    if (signal?.aborted) abort()
    await firstAudio
    signal?.throwIfAborted()
    if (header?.input?.id !== input || header.channels !== source.inputs || inputChannel > header.channels) throw new Error('Capture differs from selected calibration input')
    const reference = calibrationReference(header.sampleRate, destination.outputs, selection), referencePath = join(directory, 'reference.wav')
    await writeFile(referencePath, reference.wave, { flag: 'wx', mode: 0o600, signal })
    const plan = { schemaVersion: 1, kind: 'wave-arrangement', duration: reference.frames / reference.sampleRate,
      assets: [{ id: 'reference', path: referencePath, sha256: hash(reference.wave), sampleRate: reference.sampleRate, channels: reference.channels, frames: reference.frames }],
      regions: [{ id: 'pulse', asset: 'reference', startSeconds: 0, offsetFrames: 0, frameCount: reference.frames, repeat: 1 }] }
    const path = join(directory, 'plan.json')
    await writeFile(path, JSON.stringify(plan), { flag: 'wx', mode: 0o600, signal }); signal?.throwIfAborted()
    if (captureFailure) throw captureFailure
    player = openPlayback({ path, output, format: 'wave-arrangement', signal })
    const playback = await player.ready
    if (playback.device.outputs !== reference.channels) throw new Error('Selected calibration output channel configuration changed')
    await writeFile(join(directory, 'playback.json'), JSON.stringify(playback, null, 2), { flag: 'wx', mode: 0o600, signal })
    await player.completion
    if (captureFailure) throw captureFailure
    closingCapture = true; capture.stop(); await capture.completion; signal?.throwIfAborted()
    const result = await analyze({ directory, reference, playback, selection, signal })
    if (result.input?.id !== input) throw new Error('Final calibration input identity changed')
    await writeFile(join(directory, 'measurement.json'), JSON.stringify(result, null, 2), { flag: 'wx', mode: 0o600, signal })
    signal?.throwIfAborted()
    return { ...result, directory }
  } catch (error) {
    throw new Error(`${error.message}; calibration files retained at ${directory}`, { cause: error })
  } finally {
    signal?.removeEventListener('abort', abort); abort()
    await Promise.allSettled([capture?.completion, player?.completion])
  }
}
