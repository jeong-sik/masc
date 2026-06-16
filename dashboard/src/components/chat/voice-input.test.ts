import { beforeEach, describe, expect, it, vi } from 'vitest'

// Mock the core fetch layer so the tests exercise transcribeAudio's contract
// (path, method, raw audio body, bearer, content-type) without network I/O.
vi.mock('../../api/core', () => ({
  fetchWithTimeout: vi.fn(),
  authHeaders: () => ({ Authorization: 'Bearer test' }),
}))

import { fetchWithTimeout } from '../../api/core'
import { transcribeAudio, voiceInputSupported } from './voice-input'

const mockedFetch = vi.mocked(fetchWithTimeout)

/** The last fetch call, typed as the [path, init, timeoutMs] tuple transcribeAudio passes. */
function lastCall(): [string, RequestInit, number] {
  const call = mockedFetch.mock.calls.at(-1)
  if (!call) throw new Error('fetchWithTimeout was not called')
  return call as [string, RequestInit, number]
}

/** Cast the request headers to a plain record so strict indexing type-checks. */
function headersOf(init: RequestInit): Record<string, string> {
  return init.headers as Record<string, string>
}

function okResponse(body: unknown): Response {
  return {
    ok: true,
    status: 200,
    statusText: 'OK',
    json: () => Promise.resolve(body),
  } as unknown as Response
}

function errorResponse(body: unknown, status = 400, statusText = 'Bad Request'): Response {
  return {
    ok: false,
    status,
    statusText,
    json: () => Promise.resolve(body),
  } as unknown as Response
}

describe('transcribeAudio', () => {
  beforeEach(() => mockedFetch.mockReset())

  it('returns the transcribed text and detected language', async () => {
    mockedFetch.mockResolvedValue(okResponse({ text: '안녕하세요', language_code: 'ko' }))
    const result = await transcribeAudio(new Blob(['x'], { type: 'audio/webm' }))
    expect(result.text).toBe('안녕하세요')
    expect(result.languageCode).toBe('ko')
  })

  it('POSTs raw audio bytes with the blob content-type and bearer', async () => {
    mockedFetch.mockResolvedValue(okResponse({ text: 'hi' }))
    const blob = new Blob(['audio-bytes'], { type: 'audio/mp4' })
    await transcribeAudio(blob)
    expect(mockedFetch).toHaveBeenCalledOnce()
    const [path, init] = lastCall()
    expect(path).toBe('/api/v1/voice/transcribe')
    expect(init.method).toBe('POST')
    expect(headersOf(init)).toMatchObject({
      'content-type': 'audio/mp4',
      Authorization: 'Bearer test',
    })
    expect(init.body).toBe(blob)
  })

  it('falls back to audio/webm when the blob has no content-type', async () => {
    mockedFetch.mockResolvedValue(okResponse({ text: 'hi' }))
    await transcribeAudio(new Blob(['x']))
    const [, init] = lastCall()
    expect(headersOf(init)['content-type']).toBe('audio/webm')
  })

  it('uses a 60s timeout', async () => {
    mockedFetch.mockResolvedValue(okResponse({ text: 'hi' }))
    await transcribeAudio(new Blob(['x']))
    const [, , timeoutMs] = lastCall()
    expect(timeoutMs).toBe(60_000)
  })

  it('throws the server error message on HTTP failure', async () => {
    mockedFetch.mockResolvedValue(errorResponse({ error: 'STT request timed out' }))
    await expect(transcribeAudio(new Blob(['x']))).rejects.toThrow('STT request timed out')
  })

  it('falls back to the status line when the error body is not JSON', async () => {
    mockedFetch.mockResolvedValue({
      ok: false,
      status: 500,
      statusText: 'Internal Server Error',
      json: () => Promise.reject(new Error('not json')),
    } as unknown as Response)
    await expect(transcribeAudio(new Blob(['x']))).rejects.toThrow('500')
  })

  it('returns empty text when the server reports no speech', async () => {
    mockedFetch.mockResolvedValue(okResponse({ text: '', language_code: 'ko' }))
    const result = await transcribeAudio(new Blob(['x']))
    expect(result.text).toBe('')
    expect(result.languageCode).toBe('ko')
  })

  it('tolerates a missing language_code', async () => {
    mockedFetch.mockResolvedValue(okResponse({ text: 'hello' }))
    const result = await transcribeAudio(new Blob(['x']))
    expect(result.text).toBe('hello')
    expect(result.languageCode).toBeNull()
  })
})

describe('voiceInputSupported', () => {
  it('reports support from MediaRecorder + getUserMedia presence', () => {
    // jsdom lacks both by default; stub them to assert the positive branch.
    const origRecorder = (globalThis as { MediaRecorder?: unknown }).MediaRecorder
    const origMediaDevices = navigator.mediaDevices
    try {
      ;(globalThis as { MediaRecorder?: unknown }).MediaRecorder = class FakeRecorder {}
      Object.defineProperty(navigator, 'mediaDevices', {
        value: { getUserMedia: () => Promise.resolve(new MediaStream()) },
        configurable: true,
      })
      expect(voiceInputSupported()).toBe(true)
    } finally {
      ;(globalThis as { MediaRecorder?: unknown }).MediaRecorder = origRecorder
      Object.defineProperty(navigator, 'mediaDevices', {
        value: origMediaDevices,
        configurable: true,
      })
    }
  })

  it('reports unsupported when MediaRecorder is absent', () => {
    const origRecorder = (globalThis as { MediaRecorder?: unknown }).MediaRecorder
    try {
      delete (globalThis as { MediaRecorder?: unknown }).MediaRecorder
      expect(voiceInputSupported()).toBe(false)
    } finally {
      ;(globalThis as { MediaRecorder?: unknown }).MediaRecorder = origRecorder
    }
  })
})
