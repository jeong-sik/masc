import { afterEach, expect, it, vi } from 'vitest'
import { fetchArtifactDraft, sendArtifactDraftCommand } from './artifact-drafts'
import { sendArtifactDiscussion } from './artifact-discussion'
import { sendArtifactPresence } from './artifact-draft-live'
import { ApiRequestError } from './core'
import { captureArtifactWorkspace, fetchPublicArtifact, fetchWorkspacePublishedArtifact, setPublishedArtifactShared, publishArtifact } from './published-artifacts'

const target = { artifact_id: `artifact-${'a'.repeat(32)}`, generation: '019f0000-0000-7000-8000-000000000000' }
const workspace = { basePath: '/workspace', mascRoot: '/runtime' }
afterEach(() => { vi.unstubAllGlobals(); vi.useRealTimers() })

it.each(['merge', 'discussion', 'read', 'health', 'open', 'base'] as const)('propagates cancellation through a stalled %s response body without a retry', async kind => {
  let bodyStarted!: () => void
  const started = new Promise<void>(resolve => { bodyStarted = resolve })
  const fetchMock = vi.fn(async (_path: string, init: RequestInit) => {
    const signal = init.signal!
    return { ok: true, status: 200, statusText: 'OK', headers: new Headers({ 'x-masc-workspace-read': 'matched-v1' }), text: () => {
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
            : fetchWorkspacePublishedArtifact(target.artifact_id, '1', workspace, controller.signal)
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


it('recovers an actual 409 share receipt through the response parser', async () => {
  const operation = { id: target.artifact_id, shared: true, expectedVersion: 0,
    operationId: '019f0000-0000-7000-8000-000000000001', expectedArtifactRevision: 1, expectedArtifactSha256: 'a'.repeat(64) }
  const receipt = { id: operation.id, receipt: { operation_id: operation.operationId, expected_version: 0,
    expected_artifact_revision: 1, expected_artifact_sha256: operation.expectedArtifactSha256,
    publication_matches: false, requested: true, outcome: 'conflict', snapshot: { version: 0, shared: false } },
    current: { version: 0, shared: false } }
  const successfulOperation = { ...operation, id: `artifact-${'b'.repeat(32)}`, operationId: '019f0000-0000-7000-8000-000000000002' }
  const applied = { ...receipt, id: successfulOperation.id, receipt: { ...receipt.receipt, operation_id: successfulOperation.operationId, publication_matches: true,
    outcome: 'applied', snapshot: { version: 1, shared: true } }, current: { version: 1, shared: true } }
  const fetchMock = vi.fn()
    .mockImplementationOnce(async () => new Response(JSON.stringify(receipt), { status: 409 }))
    .mockImplementationOnce(async () => new Response(JSON.stringify(receipt), { status: 409 }))
    .mockImplementationOnce(async () => new Response(JSON.stringify(applied), { status: 200 }))
  vi.stubGlobal('fetch', fetchMock)
  expect(await setPublishedArtifactShared(operation, workspace)).toEqual(receipt)
  expect(await setPublishedArtifactShared(operation, workspace)).toEqual(receipt)
  expect(await setPublishedArtifactShared(successfulOperation, workspace)).toEqual(applied)
  expect(fetchMock).toHaveBeenCalledTimes(3)
})

it.each([
  ['share', 200, 30_000], ['share', 409, 30_000],
  ['publication', 200, 30_000], ['draft', 200, 35_000], ['public', 200, 35_000],
] as const)('limits a stalled %s body after status %i even without a caller signal', async (kind, status, timeoutMs) => {
  vi.useFakeTimers()
  let bodyStarted!: () => void
  const started = new Promise<void>(resolve => { bodyStarted = resolve })
  const fetchMock = vi.fn(async (_path: string, init: RequestInit) => {
    const signal = init.signal!
    const response = { ok: status === 200, status, statusText: '', headers: new Headers(), clone: () => response, text: () => {
      bodyStarted()
      return new Promise<string>((_resolve, reject) => {
        signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true })
      })
    } } as Response
    return response
  })
  vi.stubGlobal('fetch', fetchMock)
  const request = kind === 'share' ? setPublishedArtifactShared({ id: target.artifact_id, shared: true, expectedVersion: 0,
    operationId: '019f0000-0000-7000-8000-000000000001', expectedArtifactRevision: 1, expectedArtifactSha256: 'a'.repeat(64) }, workspace)
    : kind === 'publication' ? publishArtifact({ title: 'title', summary: '', format: 'markdown', content: 'body' }, workspace)
      : kind === 'draft' ? fetchArtifactDraft(target.artifact_id, workspace)
        : fetchPublicArtifact(target.artifact_id, undefined)
  const result = request.catch(error => error)
  await started
  await vi.advanceTimersByTimeAsync(timeoutMs)
  const error: unknown = await result
  expect(error).toBeInstanceOf(ApiRequestError)
  expect(error).toMatchObject({ timeout: true, status: undefined })
  expect(fetchMock).toHaveBeenCalledTimes(1)
  if (kind === 'public') {
    expect(fetchMock.mock.calls[0]![1].credentials).toBe('omit')
    expect(fetchMock.mock.calls[0]![1].headers).toEqual({})
  }
})
