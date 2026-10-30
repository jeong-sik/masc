import { openSync, writeSync, closeSync, readFileSync, unlinkSync } from 'node:fs'
import { createAudioExporter } from './engine.mjs'

export function waveHeader(dataBytes, sampleRate) {
  if (dataBytes > 0xffffffff - 36) throw new Error('audio exceeds the RIFF WAVE size limit')
  const header = Buffer.alloc(44)
  header.write('RIFF', 0)
  header.writeUInt32LE(36 + dataBytes, 4)
  header.write('WAVEfmt ', 8)
  header.writeUInt32LE(16, 16)
  header.writeUInt16LE(1, 20) // signed PCM, little endian
  header.writeUInt16LE(2, 22) // alphaSynth renders interleaved stereo
  header.writeUInt32LE(sampleRate, 24)
  header.writeUInt32LE(sampleRate * 4, 28)
  header.writeUInt16LE(4, 32)
  header.writeUInt16LE(16, 34)
  header.write('data', 36)
  header.writeUInt32LE(dataBytes, 40)
  return header
}

export function exportWave(source, path, { soundfontPath, tracks, cancelled = () => false } = {}) {
  const sampleRate = 44100
  const soundfont = soundfontPath ? readFileSync(soundfontPath) : undefined
  const exporter = createAudioExporter(source, { soundfont, tracks, sampleRate })
  return writeExporterWave(exporter, path, { sampleRate, cancelled })
}

export function writeExporterWave(exporter, path, { sampleRate = 44100, cancelled = () => false, frames } = {}) {
  const fd = openSync(path, 'wx', 0o600)
  let dataBytes = 0
  let peak = 0
  let clippedSamples = 0
  let complete = false
  try {
    writeSync(fd, waveHeader(0, sampleRate))
    for (let chunk; (chunk = exporter.render(500));) {
      if (cancelled()) throw new Error('audio synthesis cancelled')
      const samples = frames === undefined ? chunk.samples.length : Math.min(chunk.samples.length, frames * 2 - dataBytes / 2)
      if (samples <= 0) break
      const pcm = Buffer.alloc(samples * 2)
      for (let i = 0; i < samples; i++) {
        const sample = chunk.samples[i]
        if (!Number.isFinite(sample)) throw new Error('synthesizer produced a non-finite sample')
        peak = Math.max(peak, Math.abs(sample))
        if (sample < -1 || sample > 1) clippedSamples++
        pcm.writeInt16LE(Math.round(Math.max(-1, Math.min(1, sample)) * 32767), i * 2)
      }
      writeSync(fd, pcm)
      dataBytes += pcm.length
      waveHeader(dataBytes, sampleRate) // check the actual container boundary
    }
    writeSync(fd, waveHeader(dataBytes, sampleRate), 0, 44, 0)
    complete = true
    return { path, durationMs: dataBytes / (sampleRate * 4) * 1000, peak, clippedSamples }
  } finally {
    closeSync(fd)
    if (!complete) unlinkSync(path)
  }
}
