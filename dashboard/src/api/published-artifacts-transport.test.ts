import { afterEach, expect, it, vi } from 'vitest'
import { fetchPublicArtifact, fetchPublishedArtifact, fetchWorkspacePublishedArtifact, publishArtifact, setPublishedArtifactShared } from './published-artifacts'
import { ApiRequestError } from './core'

const workspace = { basePath: '/workspace', mascRoot: '/runtime' }
const operation = { id: `artifact-${'a'.repeat(32)}`, shared: true, expectedVersion: 0,
  operationId: '019f0000-0000-7000-8000-000000000001', expectedArtifactRevision: 1, expectedArtifactSha256: 'a'.repeat(64) }
const conflict = { id: operation.id, receipt: { operation_id: operation.operationId, expected_version: 0,
  expected_artifact_revision: 1, expected_artifact_sha256: operation.expectedArtifactSha256,
  publication_matches: false, requested: true, outcome: 'conflict', snapshot: { version: 0, shared: false } },
  current: { version: 0, shared: false } }
const successfulOperation = { ...operation, id: `artifact-${'b'.repeat(32)}`, operationId: '019f0000-0000-7000-8000-000000000002' }
const applied = { ...conflict, id: successfulOperation.id, receipt: { ...conflict.receipt, operation_id: successfulOperation.operationId, publication_matches: true,
  outcome: 'applied', snapshot: { version: 1, shared: true } }, current: { version: 1, shared: true } }
afterEach(() => { vi.unstubAllGlobals(); vi.useRealTimers() })

it('recovers a 409 receipt and its replay through the real transport parser', async () => {
  const fetchMock = vi.fn()
    .mockImplementationOnce(async () => new Response(JSON.stringify(conflict), { status: 409 }))
    .mockImplementationOnce(async () => new Response(JSON.stringify(conflict), { status: 409 }))
  vi.stubGlobal('fetch', fetchMock)
  expect(await setPublishedArtifactShared(operation, workspace)).toEqual(conflict)
  expect(await setPublishedArtifactShared(operation, workspace)).toEqual(conflict)
  expect(fetchMock).toHaveBeenCalledTimes(2)
  expect(fetchMock.mock.calls[0]![1].body).toEqual(fetchMock.mock.calls[1]![1].body)
})

it('accepts an applied receipt from a separate publication', async () => {
  const fetchMock = vi.fn(async () => new Response(JSON.stringify(applied), { status: 200 }))
  vi.stubGlobal('fetch', fetchMock)
  expect(await setPublishedArtifactShared(successfulOperation, workspace)).toEqual(applied)
  expect(fetchMock).toHaveBeenCalledTimes(1)
})

it.each([
  [409, { ...conflict, id: `artifact-${'b'.repeat(32)}` }],
  [409, { ...conflict, current: { version: 0, shared: true } }],
  [409, { ...applied, id: operation.id, receipt: { ...applied.receipt, operation_id: operation.operationId } }], [200, conflict],
  [503, { code: 'artifact_share_commit_uncertain', attempted_receipt: applied.receipt }],
] as const)('never treats status %i or a mismatched receipt as confirmation', async (status, response) => {
  const fetchMock = vi.fn(async () => new Response(JSON.stringify(response), { status }))
  vi.stubGlobal('fetch', fetchMock)
  await expect(setPublishedArtifactShared(operation, workspace)).rejects.toThrow()
  expect(fetchMock).toHaveBeenCalledTimes(1)
})


it.each([['share', 200, 30_000], ['share', 409, 30_000], ['publication', 200, 30_000], ['workspace read', 200, 35_000], ['public read', 200, 35_000]] as const)(
  'does not wait forever for a stalled %s response body after status %i', async (kind, status, timeoutMs) => {
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
    const request = kind === 'share' ? setPublishedArtifactShared(operation, workspace)
      : kind === 'publication' ? publishArtifact({ title: 'title', summary: '', format: 'markdown', content: 'body' }, workspace)
      : kind === 'workspace read' ? fetchWorkspacePublishedArtifact(operation.id, undefined, workspace)
        : fetchPublicArtifact(operation.id, undefined)
    const result = request.catch(error => error)
    await started
    await vi.advanceTimersByTimeAsync(timeoutMs)
    expect(await result).toBeInstanceOf(ApiRequestError)
    expect(await result).toMatchObject({ timeout: true, status: undefined })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    if (kind === 'public read') {
      expect(fetchMock.mock.calls[0]![1].credentials).toBe('omit')
      expect(fetchMock.mock.calls[0]![1].headers).toEqual({})
    }
  },
)


it('keeps caller cancellation connected to a normal artifact read body', async () => {
  let bodyStarted!: () => void
  const started = new Promise<void>(resolve => { bodyStarted = resolve })
  const fetchMock = vi.fn(async (_path: string, init: RequestInit) => ({
    ok: true, status: 200, statusText: 'OK', text: () => {
      bodyStarted()
      return new Promise<string>((_resolve, reject) => {
        init.signal!.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true })
      })
    },
  }) as Response)
  vi.stubGlobal('fetch', fetchMock)
  const controller = new AbortController()
  const request = fetchPublishedArtifact(operation.id, undefined, controller.signal)
  await started
  controller.abort()
  await expect(request).rejects.toMatchObject({ name: 'AbortError' })
  expect(fetchMock).toHaveBeenCalledTimes(1)
})
