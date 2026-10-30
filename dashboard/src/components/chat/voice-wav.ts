/**
 * A browser recording, re-encoded as the WAV every STT endpoint kind reads.
 *
 * `MediaRecorder` records a compressed container the browser picks — WebM in
 * Chromium. whisper-cli, the STT kind that runs without a server, does not
 * read WebM, MP4 or Ogg Opus: the server refuses those before running it. WAV
 * is read by whisper-cli and by the HTTP kinds alike, so the recording is
 * decoded here and uploaded as 16 kHz mono 16-bit PCM, the format whisper.cpp
 * transcribes and the TUI records.
 */

/** The rate whisper.cpp transcribes at and the TUI records at. */
export const TRANSCRIBE_SAMPLE_RATE = 16_000

const BITS_PER_SAMPLE = 16
const BYTES_PER_SAMPLE = BITS_PER_SAMPLE / 8
const WAV_HEADER_BYTES = 44
const RIFF_CHUNK_OVERHEAD_BYTES = 36
const FMT_CHUNK_BYTES = 16
const PCM_FORMAT = 1
const MONO = 1
const INT16_NEGATIVE_FULL_SCALE = 0x8000
const INT16_POSITIVE_FULL_SCALE = 0x7fff

/** The average of every channel, frame by frame. One channel is returned as is. */
export function mixToMono(channels: readonly Float32Array[]): Float32Array {
  const [first, ...rest] = channels
  if (first === undefined) return new Float32Array(0)
  if (rest.length === 0) return first
  const frames = Math.min(first.length, ...rest.map((channel) => channel.length))
  const mixed = new Float32Array(frames)
  for (const channel of channels) {
    for (let frame = 0; frame < frames; frame++) {
      mixed[frame] = (mixed[frame] ?? 0) + (channel[frame] ?? 0) / channels.length
    }
  }
  return mixed
}

function writeAscii(view: DataView, offset: number, text: string): void {
  for (let index = 0; index < text.length; index++) {
    view.setUint8(offset + index, text.charCodeAt(index))
  }
}

/**
 * Mono samples in [-1, 1] as a 16-bit PCM WAV file. Samples outside the range
 * are clipped to full scale rather than wrapped.
 */
export function encodeWav16(samples: Float32Array, sampleRate: number): ArrayBuffer {
  const dataBytes = samples.length * BYTES_PER_SAMPLE
  const buffer = new ArrayBuffer(WAV_HEADER_BYTES + dataBytes)
  const view = new DataView(buffer)
  writeAscii(view, 0, 'RIFF')
  view.setUint32(4, RIFF_CHUNK_OVERHEAD_BYTES + dataBytes, true)
  writeAscii(view, 8, 'WAVE')
  writeAscii(view, 12, 'fmt ')
  view.setUint32(16, FMT_CHUNK_BYTES, true)
  view.setUint16(20, PCM_FORMAT, true)
  view.setUint16(22, MONO, true)
  view.setUint32(24, sampleRate, true)
  view.setUint32(28, sampleRate * MONO * BYTES_PER_SAMPLE, true)
  view.setUint16(32, MONO * BYTES_PER_SAMPLE, true)
  view.setUint16(34, BITS_PER_SAMPLE, true)
  writeAscii(view, 36, 'data')
  view.setUint32(40, dataBytes, true)
  samples.forEach((sample, index) => {
    const clipped = Math.max(-1, Math.min(1, sample))
    const scaled =
      clipped < 0 ? clipped * INT16_NEGATIVE_FULL_SCALE : clipped * INT16_POSITIVE_FULL_SCALE
    view.setInt16(WAV_HEADER_BYTES + index * BYTES_PER_SAMPLE, Math.round(scaled), true)
  })
  return buffer
}

/** The decoded audio a recording is read back as. */
export interface DecodedAudio {
  readonly sampleRate: number
  readonly numberOfChannels: number
  getChannelData(channel: number): Float32Array
}

/** Decodes a recording's bytes, resampled to {@link TRANSCRIBE_SAMPLE_RATE}. */
export type DecodeRecording = (bytes: ArrayBuffer) => Promise<DecodedAudio>

/**
 * The browser's own decoder. `decodeAudioData` resamples to its context's rate,
 * so a context at the transcription rate hands back samples already at it; the
 * context renders nothing, and one frame is the smallest length it accepts.
 */
export const decodeWithWebAudio: DecodeRecording = (bytes) =>
  new OfflineAudioContext(MONO, 1, TRANSCRIBE_SAMPLE_RATE).decodeAudioData(bytes)

/** A recording as a 16 kHz mono WAV blob. Rejects when the browser cannot decode it. */
export async function recordingToWav(
  recording: Blob,
  decode: DecodeRecording = decodeWithWebAudio,
): Promise<Blob> {
  const decoded = await decode(await recording.arrayBuffer())
  const channels = Array.from({ length: decoded.numberOfChannels }, (_, channel) =>
    decoded.getChannelData(channel),
  )
  return new Blob([encodeWav16(mixToMono(channels), decoded.sampleRate)], {
    type: 'audio/wav',
  })
}
