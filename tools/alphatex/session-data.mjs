import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { createInterface } from 'node:readline'
import { createReadStream } from 'node:fs'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { readWaveMetadata } from './wave-file.mjs'

midiFiles(JZZ)

function integer(value, name, { positive = false } = {}) {
  if (!Number.isSafeInteger(value) || value < (positive ? 1 : 0)) throw new Error(`Invalid ${name}`)
  return value
}
function clockInteger(value, name) {
  if (typeof value !== 'string' || !/^-?\d+$/.test(value)) throw new Error(`Invalid ${name}`)
  return BigInt(value)
}

export function captureClock(clock) {
  if (clock?.kind !== 'mach-host-time') throw new Error('Unsupported capture clock')
  const origin = clockInteger(clock.requestedStart, 'clock origin')
  const numer = BigInt(integer(clock.numer, 'clock numerator', { positive: true }))
  const denom = BigInt(integer(clock.denom, 'clock denominator', { positive: true }))
  // Subtract as integers before conversion: host ticks exceed floating point precision.
  return ticks => Number((clockInteger(ticks, 'host time') - origin) * numer / denom) / 1e9
}

export async function* jsonLines(path, { signal } = {}) {
  const input = createReadStream(path, { encoding: 'utf8', signal })
  const lines = createInterface({ input, crlfDelay: Infinity })
  try {
    for await (const line of lines) {
      if (!line) throw new Error(`Empty record in ${path}`)
      yield JSON.parse(line)
    }
  } finally { lines.close(); input.destroy() }
}

export function unpackMidi(row) {
  if (row.kind !== 'midi' || row.protocol !== 2 || !Array.isArray(row.words)
      || !['packet', 'received'].includes(row.timestampOrigin) || typeof row.source !== 'string') {
    throw new Error('Invalid MIDI capture packet')
  }
  const bytes = Buffer.alloc(row.words.length * 4)
  row.words.forEach((word, index) => {
    if (!Number.isInteger(word) || word < 0 || word > 0xffffffff) throw new Error('Invalid UMP word')
    bytes.writeUInt32BE(word, index * 4)
  })
  // MIDI 2.0 UMP message type defines length, including reserved types.
  // The same table is enforced by JZZ.UMP; keep every message, not only notes.
  const sizes = [4, 4, 4, 8, 8, 16, 4, 4, 8, 8, 8, 12, 12, 16, 16, 16]
  const messages = []
  for (let offset = 0; offset < bytes.length;) {
    const end = offset + sizes[bytes[offset] >>> 4]
    if (end > bytes.length) throw new Error('Truncated UMP message')
    messages.push(JZZ.UMP([...bytes.subarray(offset, end)]))
    offset = end
  }
  return messages
}

export class CaptureTimeline {
  constructor(manifest) {
    if (manifest.schemaVersion !== 1 || !['recorded', 'failed'].includes(manifest.state)) throw new Error('Unsupported capture manifest')
    this.manifest = manifest
    this.seconds = captureClock(manifest.clock)
    this.sampleRate = integer(manifest.sampleRate, 'sample rate', { positive: true })
    this.channels = integer(manifest.channels, 'channel count', { positive: true })
    this.audio = []
    this.midi = new Map()
    this.frames = 0n
    this.packets = 0n
    this.midiTime = { first: null, last: null }
    this.ordinal = 0
    this.duration = 0
  }
  addAudio(row) {
    if (row.kind !== 'audio' || !Array.isArray(row.peaks) || row.peaks.length !== this.channels) throw new Error('Invalid audio block')
    const offset = clockInteger(row.frameOffset, 'frame offset')
    const frames = integer(row.frameCount, 'frame count', { positive: true })
    if (offset !== this.frames) throw new Error('Noncontiguous WAV frame offsets')
    const time = this.seconds(row.hostTime)
    clockInteger(row.deviceSampleTime, 'device sample time')
    const peaks = row.peaks.map(pair => {
      if (!Array.isArray(pair) || pair.length !== 2 || !pair.every(Number.isFinite) || pair[0] > pair[1]) throw new Error('Invalid waveform peak')
      return pair
    })
    this.audio.push({ hostTime: row.hostTime, deviceSampleTime: row.deviceSampleTime, time, end: time + frames / this.sampleRate, offset, frames, peaks })
    this.frames += BigInt(frames)
    this.duration = Math.max(this.duration, time + frames / this.sampleRate)
  }
  addMidi(row) {
    const time = this.seconds(row.hostTime)
    for (const message of unpackMidi(row)) {
      const type = message[0] >>> 4
      const group = message.getGroup()
      const channel = type === 2 || type === 4 ? message[1] & 15 : undefined
      const key = JSON.stringify([row.source, group ?? null, channel ?? null])
      let track = this.midi.get(key)
      if (!track) {
        const source = this.manifest.midiSources.find(source => source.id === row.source)
        track = { key, source: row.source, name: source?.name ?? row.source, group, channel, events: [], notes: [], held: new Map() }
        this.midi.set(key, track)
      }
      track.events.push({ time, message, timestampOrigin: row.timestampOrigin, ordinal: this.ordinal++ })
      if (message.isNoteOn()) {
        const note = { pitch: message[2], start: time, end: null }
        track.notes.push(note)
        const held = track.held.get(note.pitch) ?? []
        held.push(note); track.held.set(note.pitch, held)
      } else if (message.isNoteOff()) {
        const held = track.held.get(message[2])
        if (held?.length) held.shift().end = time
      }
      this.duration = Math.max(this.duration, time)
    }
    const host = clockInteger(row.hostTime, 'MIDI host time')
    if (this.midiTime.first === null || host < BigInt(this.midiTime.first)) this.midiTime.first = row.hostTime
    if (this.midiTime.last === null || host > BigInt(this.midiTime.last)) this.midiTime.last = row.hostTime
    this.packets++
  }
}

export async function readCapture(directory, options = {}) {
  return readCaptureFiles({ manifest: join(directory, 'session.json'), audio: join(directory, 'audio.wav'),
    audioBlocks: join(directory, 'audio-blocks.jsonl'), midi: join(directory, 'midi.ump.jsonl') }, options)
}
export async function readCaptureFiles(files, { signal } = {}) {
  const manifest = JSON.parse(await readFile(files.manifest, { encoding: 'utf8', signal }))
  const timeline = new CaptureTimeline(manifest)
  for await (const row of jsonLines(files.audioBlocks, { signal })) timeline.addAudio(row)
  for await (const row of jsonLines(files.midi, { signal })) timeline.addMidi(row)
  if (timeline.frames !== clockInteger(manifest.audioFrames, 'audio frame total')
      || timeline.packets !== clockInteger(manifest.midiPacketCount, 'MIDI packet total')) throw new Error('Capture manifest totals do not match recorded data')
  await readWaveMetadata(files.audio, {
    sampleRate: timeline.sampleRate, channels: timeline.channels, frames: timeline.frames,
  }, { signal })
  return timeline
}

// One MIDI 2.0 Clip per source keeps source identity as well as UMP group/channel.
// JSONL remains the authoritative, unquantized capture, including timing utility messages.
export async function exportMidiClips(timeline, directory) {
  const sources = [...new Set([...timeline.midi.values()].map(track => track.source))]
  const outputs = []
  for (const [index, source] of sources.entries()) {
    const clip = new JZZ.MIDI.Clip()
    clip.ppqn = 1000
    clip.header.add(0, JZZ.UMP.umpBPM(0, 120))
    const events = [...timeline.midi.values()].filter(track => track.source === source)
      .flatMap(track => track.events).sort((a, b) => a.time - b.time || a.ordinal - b.ordinal)
    let lastTime = 0, tick = 0, tempo = 50000000 // MIDI 2.0 tempo: 10ns per quarter note
    for (const event of events) {
      if (event.time < 0) throw new Error('MIDI event precedes the capture origin')
      // MIDI Clip owns delta/start/end messages; original packet data is retained in JSONL.
      if (event.message.isDelta() || event.message.isTicksPQN() || event.message.isStartClip() || event.message.isEndClip()) continue
      tick += (event.time - lastTime) * clip.ppqn * 1e8 / tempo
      lastTime = event.time
      clip.add(Math.round(tick), event.message)
      if (event.message.isTempo()) {
        const next = event.message.getTempo()
        if (!(next > 0)) throw new Error('Invalid captured MIDI tempo')
        tempo = next
      }
    }
    const path = join(directory, `midi-${index + 1}.midi2`)
    await writeFile(path, clip.toUint8Array(), { flag: 'wx', mode: 0o600 })
    outputs.push({ source, path })
  }
  return outputs
}

// Bucket by timeline position, preserving both extrema in each visible column.
export function waveform(timeline, channel, start, secondsPerColumn, columns) {
  const buckets = Array.from({ length: columns }, () => null)
  for (const block of timeline.audio) {
    const first = Math.max(0, Math.floor((block.time - start) / secondsPerColumn))
    const last = Math.min(columns - 1, Math.ceil((block.end - start) / secondsPerColumn) - 1)
    for (let x = first; x <= last; x++) {
      if (block.end <= start + x * secondsPerColumn || block.time >= start + (x + 1) * secondsPerColumn) continue
      const [min, max] = block.peaks[channel]
      const previous = buckets[x]
      buckets[x] = previous ? [Math.min(min, previous[0]), Math.max(max, previous[1])] : [min, max]
    }
  }
  return buckets
}
