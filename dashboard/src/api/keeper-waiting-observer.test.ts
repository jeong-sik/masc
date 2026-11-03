import { afterEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  fetchControlPlane: vi.fn(),
  ensureDevToken: vi.fn(),
}))

vi.mock('./core', () => ({
  authHeaders: () => ({ Authorization: 'Bearer observer-test' }),
  fetchControlPlane: mocks.fetchControlPlane,
}))
vi.mock('./dev-token', () => ({ ensureDevToken: mocks.ensureDevToken }))

import { observeKeeperWaitingChanges } from './keeper-waiting-observer'
import { DEFAULT_GET_TIMEOUT_MS } from '../config/constants'
import { ObserverAccessError } from '../lib/observer-protocol'

afterEach(() => {
  vi.clearAllMocks()
  vi.useRealTimers()
})

describe('Keeper waiting observer', () => {
  it('uses a scoped authenticated SSE stream without sharing the MCP session cookie', async () => {
    let source!: ReadableStreamDefaultController<Uint8Array>
    const body = new ReadableStream<Uint8Array>({ start(controller) { source = controller } })
    mocks.fetchControlPlane.mockResolvedValue(new Response(body, { headers: {
      'content-type': 'text/event-stream',
      'x-masc-sse-instance-id': 'process.workspace-epoch',
      'x-masc-sse-replay': 'fresh',
      'x-masc-sse-idle-timeout-ms': '90000',
    } }))
    const ready = vi.fn()
    const change = vi.fn()
    const abort = new AbortController()
    const run = observeKeeperWaitingChanges(abort.signal, ready, change)
    await vi.waitFor(() => expect(ready).toHaveBeenCalledWith('process.workspace-epoch'))
    expect(mocks.fetchControlPlane).toHaveBeenCalledWith('/mcp?sse_kind=observer', expect.objectContaining({
      credentials: 'omit',
      headers: expect.objectContaining({ Authorization: 'Bearer observer-test', Accept: 'text/event-stream' }),
      signal: expect.any(AbortSignal),
    }))

    const encoder = new TextEncoder()
    source.enqueue(encoder.encode('data: {"type":"schedule_store_invalidated"}\n\n'))
    source.enqueue(encoder.encode('data: {"type":"operator_pending_confirm_invalidated"}\n\n'))
    source.enqueue(encoder.encode('data: {"type":"keeper_waiting_inventory_changed","keeper_name":"alpha","queue_kind":"event_queue"}\n\n'))
    source.enqueue(encoder.encode('data: {"type":"not_relevant"}\n\n'))
    await vi.waitFor(() => expect(change).toHaveBeenCalledTimes(3))
    expect(change.mock.calls).toEqual([
      [{ scope: 'workspace' }],
      [{ scope: 'workspace' }],
      [{ scope: 'keeper', keeperName: 'alpha' }],
    ])
    source.close()
    await expect(run).rejects.toThrow('observer stream closed')
  })

  it.each([null, '', '0', '-1', '1.5', '2147483648'])('refuses an invalid idle deadline %s', async deadline => {
    const headers = new Headers({
      'content-type': 'text/event-stream',
      'x-masc-sse-instance-id': 'process.workspace-epoch',
      'x-masc-sse-replay': 'fresh',
    })
    if (deadline !== null) headers.set('x-masc-sse-idle-timeout-ms', deadline)
    mocks.fetchControlPlane.mockResolvedValue(new Response('retry: 3000\n\n', { headers }))
    const ready = vi.fn()
    await expect(observeKeeperWaitingChanges(new AbortController().signal, ready, vi.fn()))
      .rejects.toThrow('observer idle deadline')
    expect(ready).not.toHaveBeenCalled()
  })

  it('times out a stalled connection attempt and forwards caller cancellation', async () => {
    vi.useFakeTimers()
    mocks.fetchControlPlane.mockImplementation((_path: string, options: RequestInit) =>
      new Promise((_resolve, reject) => {
        options.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')), { once: true })
      }))
    const timed = observeKeeperWaitingChanges(new AbortController().signal, vi.fn(), vi.fn())
      .then(() => null, error => error)
    await vi.advanceTimersByTimeAsync(DEFAULT_GET_TIMEOUT_MS)
    expect(await timed).toEqual(expect.objectContaining({ message: 'observer connection timed out' }))

    const abort = new AbortController()
    const stopped = observeKeeperWaitingChanges(abort.signal, vi.fn(), vi.fn())
      .then(() => null, error => error)
    await vi.advanceTimersByTimeAsync(0)
    abort.abort()
    expect(await stopped).toEqual(expect.objectContaining({ name: 'AbortError' }))
  })

  it('refuses a stream that does not attest its observer generation', async () => {
    mocks.fetchControlPlane.mockResolvedValue(new Response('retry: 3000\n\n', { headers: {
      'content-type': 'text/event-stream',
      'x-masc-sse-replay': 'fresh',
    } }))
    const ready = vi.fn()
    await expect(observeKeeperWaitingChanges(new AbortController().signal, ready, vi.fn()))
      .rejects.toThrow('observer generation')
    expect(ready).not.toHaveBeenCalled()
  })

  it.each([401, 403])('reports observer access refusal %s distinctly', async status => {
    mocks.fetchControlPlane.mockResolvedValue(new Response('', { status }))
    await expect(observeKeeperWaitingChanges(new AbortController().signal, vi.fn(), vi.fn()))
      .rejects.toBeInstanceOf(ObserverAccessError)
  })

  it('reports refused observer headers even if cancelling their body never settles', async () => {
    const cancel = vi.fn(() => new Promise<void>(() => {}))
    const body = new ReadableStream<Uint8Array>({ cancel })
    mocks.fetchControlPlane.mockResolvedValue(new Response(body, { headers: {
      'content-type': 'text/event-stream',
      'x-masc-sse-replay': 'fresh',
    } }))
    await expect(observeKeeperWaitingChanges(new AbortController().signal, vi.fn(), vi.fn()))
      .rejects.toThrow('observer generation')
    expect(cancel).toHaveBeenCalledOnce()
  })
})
