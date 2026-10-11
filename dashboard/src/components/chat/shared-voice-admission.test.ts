// @vitest-environment jsdom
import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { ChatComposer } from './primitives'
import { _resetChatStoreForTests, writeKeeperDraft, readKeeperDraftSnapshot } from '../../keeper-chat-store'

vi.mock('./voice-wav', () => ({ recordingToWav: async () => new Blob(['wav'], { type: 'audio/wav' }) }))
let recorder: FakeRecorder
class FakeRecorder {
  state = 'inactive'
  mimeType = 'audio/webm'
  ondataavailable: ((event: BlobEvent) => void) | null = null
  onstop: (() => void) | null = null
  onerror: (() => void) | null = null
  constructor() { recorder = this }
  start() { this.state = 'recording' }
  stop() { this.state = 'inactive'; this.onstop?.() }
}
let container: HTMLDivElement
const getUserMedia = vi.fn()
const onSend = vi.fn()
const stream = { getTracks: () => [{ stop: vi.fn() }] } as unknown as MediaStream
beforeEach(() => {
  _resetChatStoreForTests(); getUserMedia.mockReset(); onSend.mockReset()
  container = document.createElement('div')
  vi.stubGlobal('MediaRecorder', FakeRecorder)
  Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: { getUserMedia } })
  writeKeeperDraft('shared-voice', 'authored text')
  render(html`<div data-owner="main"><${ChatComposer} draftPersistKey="shared-voice" placeholder="input" disabled=${false} streaming=${false} onSend=${onSend} /></div><div data-owner="dock"><${ChatComposer} draftPersistKey="shared-voice" placeholder="input" disabled=${false} streaming=${false} onSend=${onSend} /></div>`, container)
})
afterEach(() => { render(null, container); vi.unstubAllGlobals() })
it('keeps the shared draft unsent while another composer acquires voice input', async () => {
  let resolve!: (value: MediaStream) => void
  getUserMedia.mockReturnValue(new Promise(done => { resolve = done }))
  fireEvent.click(container.querySelector('[data-owner="main"] [aria-label="음성으로 입력"]')!)
  await act(async () => {})
  fireEvent.keyDown(container.querySelector('[data-owner="dock"] textarea')!, { key: 'Enter' })
  expect(onSend).not.toHaveBeenCalled()
  await act(async () => { resolve(stream) })
})
it('admits a single voice capture across two composers for the same draft', async () => {
  let resolve!: (value: MediaStream) => void
  getUserMedia.mockReturnValue(new Promise(done => { resolve = done }))
  fireEvent.click(container.querySelector('[data-owner="main"] [aria-label="음성으로 입력"]')!)
  fireEvent.click(container.querySelector('[data-owner="dock"] [aria-label="음성으로 입력"]')!)
  expect(getUserMedia).toHaveBeenCalledTimes(1)
  await act(async () => { resolve(stream) })
})

it('submits the completed voice with the original shared text after transcription settles', async () => {
  getUserMedia.mockResolvedValue(stream)
  let resolve!: (value: Response) => void
  const fetch = vi.fn().mockReturnValue(new Promise(done => { resolve = done }))
  vi.stubGlobal('fetch', fetch)
  await act(async () => { fireEvent.click(container.querySelector('[data-owner="main"] [aria-label="음성으로 입력"]')!) })
  expect(readKeeperDraftSnapshot('shared-voice').pendingVoice?.phase).toBe('recording')
  recorder.ondataavailable?.({ data: new Blob(['audio']) } as BlobEvent)
  await act(async () => { fireEvent.click(container.querySelector('[data-owner="main"] [title="녹음 종료 — 받아쓰기"]')!) })
  expect(readKeeperDraftSnapshot('shared-voice').pendingVoice?.phase).toBe('transcribing')
  fireEvent.keyDown(container.querySelector('[data-owner="dock"] textarea')!, { key: 'Enter' })
  expect(onSend).not.toHaveBeenCalled()
  await act(async () => { resolve(new Response(JSON.stringify({ text: 'spoken text' }))) })
  await waitFor(() => expect(readKeeperDraftSnapshot('shared-voice').pendingVoice).toBeNull())
  expect(readKeeperDraftSnapshot('shared-voice').voiceDraft?.transcript).toBe('spoken text')
  fireEvent.keyDown(container.querySelector('[data-owner="dock"] textarea')!, { key: 'Enter' })
  expect(onSend).toHaveBeenCalledTimes(1)
  expect(onSend.mock.calls[0]?.[0].text).toContain('authored text')
  expect(onSend.mock.calls[0]?.[0].text).toContain('spoken text')
})

it('releases shared voice admission after permission failure while retaining authored text', async () => {
  getUserMedia.mockRejectedValue(new DOMException('denied', 'NotAllowedError'))
  await act(async () => { fireEvent.click(container.querySelector('[data-owner="main"] [aria-label="음성으로 입력"]')!) })
  expect(readKeeperDraftSnapshot('shared-voice').pendingVoice).toBeNull()
  expect(readKeeperDraftSnapshot('shared-voice').text).toBe('authored text')
  fireEvent.keyDown(container.querySelector('[data-owner="dock"] textarea')!, { key: 'Enter' })
  expect(onSend).toHaveBeenCalledTimes(1)
})
