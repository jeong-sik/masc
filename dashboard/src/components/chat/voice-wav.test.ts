import { describe, expect, it } from 'vitest'
import {
  type DecodedAudio,
  TRANSCRIBE_SAMPLE_RATE,
  encodeWav16,
  mixToMono,
  recordingToWav,
} from './voice-wav'

function ascii(view: DataView, offset: number, length: number): string {
  return String.fromCharCode(
    ...Array.from({ length }, (_, index) => view.getUint8(offset + index)),
  )
}

describe('encodeWav16', () => {
  it('writes the 44-byte header whisper.cpp reads as 16 kHz mono 16-bit PCM', () => {
    const view = new DataView(encodeWav16(new Float32Array(10), TRANSCRIBE_SAMPLE_RATE))
    expect(view.byteLength).toBe(44 + 20)
    expect(ascii(view, 0, 4)).toBe('RIFF')
    expect(view.getUint32(4, true)).toBe(36 + 20)
    expect(ascii(view, 8, 4)).toBe('WAVE')
    expect(ascii(view, 12, 4)).toBe('fmt ')
    expect(view.getUint32(16, true)).toBe(16)
    expect(view.getUint16(20, true)).toBe(1)
    expect(view.getUint16(22, true)).toBe(1)
    expect(view.getUint32(24, true)).toBe(16_000)
    expect(view.getUint32(28, true)).toBe(32_000)
    expect(view.getUint16(32, true)).toBe(2)
    expect(view.getUint16(34, true)).toBe(16)
    expect(ascii(view, 36, 4)).toBe('data')
    expect(view.getUint32(40, true)).toBe(20)
  })

  it('scales to full scale and clips what lies outside [-1, 1]', () => {
    const view = new DataView(
      encodeWav16(new Float32Array([0, 1, -1, 0.5, 2, -3]), TRANSCRIBE_SAMPLE_RATE),
    )
    const sample = (index: number) => view.getInt16(44 + index * 2, true)
    expect(sample(0)).toBe(0)
    expect(sample(1)).toBe(32_767)
    expect(sample(2)).toBe(-32_768)
    expect(sample(3)).toBe(16_384)
    expect(sample(4)).toBe(32_767)
    expect(sample(5)).toBe(-32_768)
  })
})

describe('mixToMono', () => {
  it('returns a single channel unchanged', () => {
    const only = new Float32Array([0.25, -0.5])
    expect(mixToMono([only])).toBe(only)
  })

  it('averages channels frame by frame, to the shortest channel', () => {
    const mixed = mixToMono([new Float32Array([1, 0, 0.5]), new Float32Array([0, -1])])
    expect(Array.from(mixed)).toEqual([0.5, -0.5])
  })

  it('answers no channels with no samples', () => {
    expect(mixToMono([]).length).toBe(0)
  })
})

describe('recordingToWav', () => {
  it('uploads what the decoder hands back, mixed to mono, at its rate', async () => {
    const left = new Float32Array([1, 1, 1, 1])
    const right = new Float32Array([0, 0, 0, 0])
    let decodedBytes = 0
    const decode = (bytes: ArrayBuffer): Promise<DecodedAudio> => {
      decodedBytes = bytes.byteLength
      return Promise.resolve({
        sampleRate: TRANSCRIBE_SAMPLE_RATE,
        numberOfChannels: 2,
        getChannelData: (channel: number) => (channel === 0 ? left : right),
      })
    }
    const wav = await recordingToWav(new Blob(['webm-bytes'], { type: 'audio/webm' }), decode)
    expect(decodedBytes).toBe('webm-bytes'.length)
    expect(wav.type).toBe('audio/wav')
    const view = new DataView(await wav.arrayBuffer())
    expect(view.getUint32(24, true)).toBe(TRANSCRIBE_SAMPLE_RATE)
    expect(view.getUint32(40, true)).toBe(8)
    expect(view.getInt16(44, true)).toBe(16_384)
  })

  it('rejects when the recording cannot be decoded', async () => {
    const decode = (): Promise<DecodedAudio> => Promise.reject(new Error('EncodingError'))
    await expect(recordingToWav(new Blob(['x']), decode)).rejects.toThrow('EncodingError')
  })
})
