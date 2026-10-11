// @vitest-environment jsdom
import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { clearStoredToken, setStoredToken } from '../../api/core'
import { recordingToWav } from './voice-wav'
vi.mock('./voice-wav', () => ({ recordingToWav: vi.fn() }))
import { useVoiceInput, type UseVoiceInput } from './voice-input'

let voice: UseVoiceInput
let container: HTMLDivElement
const getUserMedia = vi.fn()
const stopTrack = vi.fn()
const startRecorder = vi.fn()
const onTranscribed = vi.fn()
const onError = vi.fn()
let recorder: FakeRecorder
class FakeRecorder {
  state = 'inactive'
  mimeType = 'audio/webm'
  ondataavailable: ((event: BlobEvent) => void) | null = null
  onstop: (() => void) | null = null
  onerror: (() => void) | null = null
  constructor() { recorder = this }
  start() { startRecorder(); this.state = 'recording' }
  stop() { this.state = 'inactive'; this.onstop?.() }
}
const stream = { getTracks: () => [{ stop: stopTrack }] } as unknown as MediaStream
function Harness() { voice = useVoiceInput({ onTranscribed, onError }); return html`<div />` }
beforeEach(() => {
  container = document.createElement('div')
  getUserMedia.mockReset(); stopTrack.mockReset(); startRecorder.mockReset(); onTranscribed.mockReset(); onError.mockReset()
  vi.mocked(recordingToWav).mockResolvedValue(new Blob(['wav'], { type: 'audio/wav' }))
  vi.stubGlobal('MediaRecorder', FakeRecorder)
  Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: { getUserMedia } })
  render(html`<${Harness} />`, container)
})
afterEach(() => { render(null, container); vi.unstubAllGlobals(); clearStoredToken() })

it('releases a microphone that resolves after its composer unmounts', async () => {
  let resolve!: (value: MediaStream) => void
  getUserMedia.mockReturnValue(new Promise(done => { resolve = done }))
  const started = voice.start()
  render(null, container)
  await act(async () => { resolve(stream); await started })
  expect(startRecorder).not.toHaveBeenCalled()
  expect(stopTrack).toHaveBeenCalledTimes(1)
})

it('admits one microphone request before permission resolves', async () => {
  let resolve!: (value: MediaStream) => void
  getUserMedia.mockReturnValue(new Promise(done => { resolve = done }))
  const first = voice.start()
  const second = voice.start()
  expect(getUserMedia).toHaveBeenCalledTimes(1)
  await act(async () => { resolve(stream); await Promise.all([first, second]) })
})

it('releases a late microphone after credentials change', async () => {
  let resolve!: (value: MediaStream) => void
  getUserMedia.mockReturnValue(new Promise(done => { resolve = done }))
  const started = voice.start()
  setStoredToken('replacement-test-token')
  await act(async () => { resolve(stream); await started })
  expect(startRecorder).not.toHaveBeenCalled()
  expect(stopTrack).toHaveBeenCalledTimes(1)
  expect(onError).not.toHaveBeenCalled()
})

it('aborts transcription on unmount and rejects its late result', async () => {
  let resolve!: (value: Response) => void
  const fetch = vi.fn().mockReturnValue(new Promise(done => { resolve = done }))
  vi.stubGlobal('fetch', fetch)
  getUserMedia.mockResolvedValue(stream)
  await act(async () => { await voice.start() })
  recorder.ondataavailable?.({ data: new Blob(['audio']) } as BlobEvent)
  await act(async () => { voice.stop() })
  expect(fetch).toHaveBeenCalledTimes(1)
  const signal = fetch.mock.calls[0]?.[1].signal as AbortSignal
  expect(signal.aborted).toBe(false)
  render(null, container)
  expect(signal.aborted).toBe(true)
  await act(async () => { resolve(new Response(JSON.stringify({ text: 'late text' }))) })
  expect(onTranscribed).not.toHaveBeenCalled()
  expect(onError).not.toHaveBeenCalled()
})

it('does not upload converted audio after its credentials change', async () => {
  let resolve!: (value: Blob) => void
  vi.mocked(recordingToWav).mockReturnValue(new Promise(done => { resolve = done }))
  const fetch = vi.fn()
  vi.stubGlobal('fetch', fetch)
  getUserMedia.mockResolvedValue(stream)
  await act(async () => { await voice.start() })
  recorder.ondataavailable?.({ data: new Blob(['audio']) } as BlobEvent)
  voice.stop()
  setStoredToken('replacement-test-token')
  await act(async () => { resolve(new Blob(['wav'])) })
  expect(fetch).not.toHaveBeenCalled()
  expect(onTranscribed).not.toHaveBeenCalled()
})
