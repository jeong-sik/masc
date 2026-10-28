import { afterEach, expect, it, vi } from 'vitest'
import { fetchArtifactDraft, sendArtifactDraftCommand } from './artifact-drafts'
import { sendArtifactDiscussion } from './artifact-discussion'
import { sendArtifactPresence } from './artifact-draft-live'
import { ApiRequestError } from './core'
import { captureArtifactWorkspace, fetchPublishedArtifact } from './published-artifacts'

const target = { artifact_id: `artifact-${'a'.repeat(32)}`, generation: '019f0000-0000-7000-8000-000000000000' }
const workspace = { basePath: '/workspace', mascRoot: '/runtime' }
afterEach(() => { vi.unstubAllGlobals(); vi.useRealTimers() })

it.each(['merge', 'discussion', 'read', 'health', 'open', 'base'] as const)('propagates cancellation through a stalled %s response body without a retry', async kind => {
  let bodyStarted!: () => void
  const started = new Promise<void>(resolve => { bodyStarted = resolve })
  const fetchMock = vi.fn(async (_path: string, init: RequestInit) => {
    const signal = init.signal!
    return { ok: true, status: 200, statusText: 'OK', text: () => {
      bodyStarted()
      return new Promise<string>((_resolve, reject) => {
        signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true })
      })
    } } as Response
  })
  vi.stubGlobal('fetch', fetchMock)
  const controller = new AbortController()
  const request = kind === 'merge' ? sendArtifactDraftCommand({ action: 'merge', target, updates: ['AAA='] }, workspace, controller.signal)
    : kind === 'discussion' ? sendArtifactDiscussion(target, { id: target.generation,
      command: { kind: 'reply', thread_id: target.generation, body: 'hello' } }, workspace, controller.signal)
      : kind === 'read' ? fetchArtifactDraft(target.artifact_id, workspace, controller.signal)
        : kind === 'health' ? captureArtifactWorkspace(workspace.basePath, controller.signal)
          : kind === 'open' ? sendArtifactDraftCommand({ action: 'open', artifact_id: target.artifact_id, revision: 1 }, workspace, controller.signal)
            : fetchPublishedArtifact(target.artifact_id, '1', controller.signal, workspace, true)
  await started
  const upstream = fetchMock.mock.calls[0]![1].signal!
  expect(upstream.aborted).toBe(false)
  controller.abort()
  await expect(request).rejects.toMatchObject({ name: 'AbortError' })
  expect(upstream.aborted).toBe(true)
  expect(fetchMock).toHaveBeenCalledTimes(1)
})

it.each([
  ['merge', 200, 30_000], ['merge', 409, 30_000],
  ['read', 200, 35_000], ['read', 409, 35_000],
] as const)('classifies a %s body timeout after status %i as uncertain', async (kind, status, timeoutMs) => {
  vi.useFakeTimers()
  let bodyStarted!: () => void
  const started = new Promise<void>(resolve => { bodyStarted = resolve })
  const fetchMock = vi.fn(async (_path: string, init: RequestInit) => {
    const signal = init.signal!
    const response = { ok: status === 200, status, statusText: '', clone: () => response, text: () => {
      bodyStarted()
      return new Promise<string>((_resolve, reject) => {
        signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true })
      })
    } } as Response
    return response
  })
  vi.stubGlobal('fetch', fetchMock)
  const controller = new AbortController()
  const request = kind === 'merge' ? sendArtifactDraftCommand({ action: 'merge', target, updates: ['AAA='] }, workspace, controller.signal)
    : fetchArtifactDraft(target.artifact_id, workspace, controller.signal)
  const result = request.catch(error => error)
  await started
  await vi.advanceTimersByTimeAsync(timeoutMs)
  const error: unknown = await result
  expect(error).toBeInstanceOf(ApiRequestError)
  expect(error).toMatchObject({ timeout: true, status: undefined })
  expect(controller.signal.aborted).toBe(false)
  expect(fetchMock).toHaveBeenCalledTimes(1)
})

it('propagates cancellation to a pending presence fetch', async () => {
  const fetchMock = vi.fn((_path: string, init: RequestInit) => new Promise<Response>((_resolve, reject) => {
    init.signal!.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true })
  }))
  vi.stubGlobal('fetch', fetchMock)
  const controller = new AbortController()
  const request = sendArtifactPresence(target, 'old-session', workspace, { action: 'position', position: null }, controller.signal)
  expect(fetchMock).toHaveBeenCalledTimes(1)
  controller.abort()
  await expect(request).rejects.toThrow()
  expect(fetchMock.mock.calls[0]![1].signal!.aborted).toBe(true)
})
