import { confirmRuntimeTestWorkspace, RUNTIME_TEST_OBSERVER_INSTANCE } from '../lib/runtime-workspace.test-fixture'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { readQueryObservationStream, QueryStreamProtocolError, QueryStreamScopeError } from './query-observation-stream'
import { createQueryObservationStream } from '../lib/query-observation-stream'
import { executionWorkspaceAuthority, hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../store'
import { dashboardObserverInstance } from '../dashboard-observer-state'

vi.mock('./dev-token', () => ({ ensureDevToken: vi.fn(async () => {}), refreshDevTokenAfterAuthError: vi.fn(async () => false) }))

const disposers: Array<() => void> = []
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve() }
const headers = { 'content-type': 'text/event-stream', 'x-masc-sse-idle-timeout-ms': '100', 'x-masc-sse-instance-id': RUNTIME_TEST_OBSERVER_INSTANCE }
beforeEach(confirmRuntimeTestWorkspace)
afterEach(() => {
  for (const stop of disposers.splice(0)) stop()
  vi.unstubAllGlobals()
  vi.useRealTimers()
  dashboardObserverInstance.value = null
})

function nativeOwner() {
  return createQueryObservationStream<string, unknown, Error>({
    key: path => path, recoveryTopics: ['tool_metrics'],
    read: (path, _previous, signal, onFrame, onActivity, instance) =>
      readQueryObservationStream(path, instance, signal, wire => wire, onFrame, onActivity),
    merge: (_previous, frame) => frame,
    readOutcome: () => 'complete',
    failure: cause => cause instanceof Error ? cause : new Error(String(cause)),
    terminal: cause => cause instanceof QueryStreamProtocolError,
  })
}

describe('native query original authority', () => {
  it('rejects server B before its execution publication reaches a client still holding A', async () => {
    vi.useFakeTimers()
    let resolve!: (response: Response) => void
    const first = new Promise<Response>(done => { resolve = done })
    const secondBody = new ReadableStream<Uint8Array>({ start(source) {
      source.enqueue(new TextEncoder().encode('data: {"workspace":"B"}\n\n'))
    } })
    const fetch = vi.fn().mockReturnValueOnce(first).mockResolvedValueOnce(new Response(secondBody, {
      headers: { ...headers, 'x-masc-sse-instance-id': 'observer-B' },
    }))
    vi.stubGlobal('fetch', fetch)
    const original = executionWorkspaceAuthority.peek()!
    const frame = vi.fn(), error = vi.fn()
    const stop = nativeOwner()('/native', { onFrame: frame, onError: error, onReset: vi.fn() })
    disposers.push(stop)
    await flush()
    expect(new Headers(fetch.mock.calls[0]![1].headers).get('x-masc-sse-instance-id'))
      .toBe(original.observerInstanceId)
    // The common observer has seen B, but A's execution response still owns
    // this read. A current handshake must never be borrowed by the old owner.
    dashboardObserverInstance.value = 'observer-B'
    const cancel = vi.fn()
    const wrong = new ReadableStream<Uint8Array>({ start(source) {
      source.enqueue(new TextEncoder().encode('data: {"workspace":"B"}\n\n'))
    }, cancel })
    resolve(new Response(wrong, { headers: { ...headers, 'x-masc-sse-instance-id': 'observer-B' } }))
    await flush()
    expect(executionWorkspaceAuthority.peek()).toBe(original)
    expect(frame).not.toHaveBeenCalled()
    expect(error.mock.calls[0]?.[0]).toBeInstanceOf(QueryStreamScopeError)
    expect(cancel).toHaveBeenCalledOnce()
    stop.refresh()
    window.dispatchEvent(new Event('online'))
    await vi.advanceTimersByTimeAsync(120_000)
    expect(fetch).toHaveBeenCalledOnce()
    expect(vi.getTimerCount()).toBe(0)
    // A same-path new scope is still a different owner even while the
    // process execution epoch and the selected root stay equal.
    hydrateExecutionSnapshot({ projection_diagnostics: { read_completeness: 'complete', read_error: null }, observer_instance_id: 'observer-B',
      execution_publication_epoch: original.epoch, execution_publication_generation: 2,
      status: { project: 'fixture', workspace_root: original.workspaceRoot },
    } as Parameters<typeof hydrateExecutionSnapshot>[0])
    await flush()
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(new Headers(fetch.mock.calls[1]![1].headers).get('x-masc-sse-instance-id')).toBe('observer-B')
    expect(frame).toHaveBeenCalledWith({ workspace: 'B' })
    stop()
    await flush()
    expect(vi.getTimerCount()).toBe(0)
  })

  it('waits without GET or retry when the accepted execution has no original instance', async () => {
    vi.useFakeTimers()
    const epoch = 'scope-unavailable'
    invalidateExecutionSnapshotGeneration(epoch, 0)
    hydrateExecutionSnapshot({ projection_diagnostics: { read_completeness: 'complete', read_error: null }, execution_publication_epoch: epoch, execution_publication_generation: 1,
      status: { project: 'fixture', workspace_root: '/fixture/runtime-consumer' },
    } as Parameters<typeof hydrateExecutionSnapshot>[0])
    dashboardObserverInstance.value = 'current-handshake-is-not-original'
    const fetch = vi.fn()
    vi.stubGlobal('fetch', fetch)
    const error = vi.fn()
    const stop = nativeOwner()('/native', { onFrame: vi.fn(), onError: error, onReset: vi.fn() })
    disposers.push(stop)
    await flush()
    stop.refresh()
    window.dispatchEvent(new Event('online'))
    await vi.advanceTimersByTimeAsync(120_000)
    expect(fetch).not.toHaveBeenCalled()
    expect(error).toHaveBeenCalledOnce()
    expect(error.mock.calls[0]![0]).toBeInstanceOf(QueryStreamScopeError)
    expect(vi.getTimerCount()).toBe(0)
  })

  it.each(['observer_instance_changed', 'observer_instance_required', 'observer_instance_ambiguous'])(
    'waits for new authority after the server refuses %s', async code => {
      vi.useFakeTimers()
      const fetch = vi.fn(async () => new Response(JSON.stringify({ code, error: 'scope refused' }), {
        status: code === 'observer_instance_changed' ? 409 : 400,
      }))
      vi.stubGlobal('fetch', fetch)
      const error = vi.fn()
      const stop = nativeOwner()('/native', { onFrame: vi.fn(), onError: error, onReset: vi.fn() })
      disposers.push(stop)
      await flush()
      stop.refresh()
      await vi.advanceTimersByTimeAsync(120_000)
      expect(fetch).toHaveBeenCalledOnce()
      expect(error.mock.calls[0]![0]).toBeInstanceOf(QueryStreamScopeError)
      expect(vi.getTimerCount()).toBe(0)
    })
})

describe('native query byte deadline', () => {
  it('counts keepalive bytes as activity, then cancels and unlocks a silently stalled body', async () => {
    vi.useFakeTimers()
    let writer!: ReadableStreamDefaultController<Uint8Array>
    const cancel = vi.fn()
    const body = new ReadableStream<Uint8Array>({ start: controller => { writer = controller }, cancel })
    const fetch = vi.fn().mockResolvedValue(new Response(body, { headers }))
    vi.stubGlobal('fetch', fetch)
    const activity = vi.fn(), frame = vi.fn()
    const result = readQueryObservationStream('/native', RUNTIME_TEST_OBSERVER_INSTANCE, new AbortController().signal,
      wire => wire, frame, activity).catch(error => error as Error)
    await flush()
    await vi.advanceTimersByTimeAsync(99)
    writer.enqueue(new TextEncoder().encode(': keepalive\n\n'))
    await flush()
    expect(activity).toHaveBeenCalledTimes(1)
    expect(frame).not.toHaveBeenCalled()
    writer.enqueue(new Uint8Array())
    await vi.advanceTimersByTimeAsync(99)
    expect(cancel).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1)
    expect(await result).toMatchObject({ message: expect.stringMatching(/idle timeout/) })
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(cancel).toHaveBeenCalledTimes(1)
    expect(body.locked).toBe(false)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('opens again only after a failed body and retires the active deadline on last release', async () => {
    vi.useFakeTimers()
    const cancelled = vi.fn()
    const fetch = vi.fn().mockImplementation(async () => new Response(
      new ReadableStream<Uint8Array>({ cancel: cancelled }), { headers }))
    vi.stubGlobal('fetch', fetch)
    const subscribe = createQueryObservationStream<string, unknown, Error>({
      key: path => path, recoveryTopics: ['tool_metrics'],
      read: (path, _previous, signal, onFrame, onActivity, instance) =>
        readQueryObservationStream(path, instance, signal, wire => wire, onFrame, onActivity),
      merge: (_previous, frame) => frame,
      readOutcome: () => 'complete',
      failure: cause => cause instanceof Error ? cause : new Error(String(cause)),
      terminal: cause => cause instanceof QueryStreamProtocolError,
    })
    const error = vi.fn()
    const stop = subscribe('/native', { onFrame: vi.fn(), onError: error, onReset: vi.fn() })
    disposers.push(stop)
    await flush()
    expect(fetch).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(99)
    expect(fetch).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(error).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(999)
    expect(fetch).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(fetch).toHaveBeenCalledTimes(2)
    stop()
    await flush()
    expect(cancelled).toHaveBeenCalledTimes(2)
    expect(vi.getTimerCount()).toBe(0)
    await vi.advanceTimersByTimeAsync(120_000)
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it.each([undefined, '0', '-1', '1.2', '2147483648'])('refuses unavailable or clamped deadline %s', async deadline => {
    const cancel = vi.fn()
    const body = new ReadableStream<Uint8Array>({ cancel })
    const responseHeaders: Record<string, string> = { 'content-type': 'text/event-stream', 'x-masc-sse-instance-id': RUNTIME_TEST_OBSERVER_INSTANCE }
    if (deadline !== undefined) responseHeaders['x-masc-sse-idle-timeout-ms'] = deadline
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(body, { headers: responseHeaders })))
    await expect(readQueryObservationStream('/native', RUNTIME_TEST_OBSERVER_INSTANCE, new AbortController().signal, wire => wire, vi.fn()))
      .rejects.toBeInstanceOf(QueryStreamProtocolError)
    expect(cancel).toHaveBeenCalledTimes(1)
  })
})
