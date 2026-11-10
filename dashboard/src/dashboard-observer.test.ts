import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  fetch: vi.fn(), ensure: vi.fn(), refresh: vi.fn(), route: vi.fn(), record: vi.fn(),
  token: 'first', changed: null as null | (() => void),
}))
vi.mock('./api/core', () => ({
  fetchControlPlane: mocks.fetch,
  authHeaders: () => ({ Authorization: `Bearer ${mocks.token}` }),
  subscribeStoredTokenChanges: (callback: () => void) => {
    mocks.changed = callback
    return () => { mocks.changed = null }
  },
}))
vi.mock('./api/dev-token', () => ({
  ensureDevToken: mocks.ensure,
  refreshDevTokenAfterAuthError: mocks.refresh,
  hasPendingDevTokenFailure: () => false,
  pendingDevTokenRetryDelayMs: () => 0,
}))
vi.mock('./sse-store', () => ({ routeServerPushEvent: mocks.route }))
vi.mock('./sse', () => ({ recordServerPushEvent: mocks.record }))

import { connectDashboardObserver, disconnectDashboardObserver, receiveDashboardObserverEvent } from './dashboard-observer'
import { dashboardObserverReady, dashboardObserverAdmissionCount, _resetDashboardObserverCounterForTests } from './dashboard-observer-state'
import * as observerState from './dashboard-observer-state'
import { subscribeDashboardObservation } from './lib/observation-refresh'
import { TRANSPORT_RETRY_BASE_MS } from './config/constants'

const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve() }
let source: ReadableStreamDefaultController<Uint8Array>
function response(instance = 'process.workspace-epoch') {
  return new Response(new ReadableStream<Uint8Array>({ start(controller) { source = controller } }), {
    headers: { 'content-type': 'text/event-stream', 'x-masc-sse-instance-id': instance,
      'x-masc-sse-replay': 'fresh', 'x-masc-sse-idle-timeout-ms': '90000' },
  })
}

beforeEach(() => {
  vi.useFakeTimers()
  vi.clearAllMocks()
  mocks.token = 'first'
  mocks.ensure.mockResolvedValue(undefined)
  mocks.refresh.mockResolvedValue(false)
  _resetDashboardObserverCounterForTests()
})
afterEach(() => { disconnectDashboardObserver(); vi.useRealTimers() })

describe('Dashboard observation SSE', () => {
  it.each([
    '{',
    JSON.stringify({ type: 'workspace_dataset_changed', dataset: 'dashboard_observation',
      topic: 'health', scope: ['future_scope', 'unconfirmed'] }),
    JSON.stringify({ type: 'workspace_dataset_changed', dataset: 'dashboard_observation',
      topic: 'health', scope: ['keeper', ' '] }),
  ])('discards one invalid frame and delivers the next frame on the same admitted stream: %s', async invalid => {
    mocks.fetch.mockResolvedValue(response())
    const changed = vi.fn(), recovery = vi.fn()
    const unsubscribe = subscribeDashboardObservation({ topics: ['health'] }, changed, recovery)
    try {
      connectDashboardObserver()
      await flush()
      const valid = JSON.stringify({ type: 'workspace_dataset_changed', dataset: 'dashboard_observation',
        topic: 'health', scope: 'workspace' })
      source.enqueue(new TextEncoder().encode(`data: ${invalid}\n\ndata: ${valid}\n\n`))
      await flush()
      expect(dashboardObserverReady.peek()).toBe(true)
      expect(changed).toHaveBeenCalledTimes(1)
      expect(observerState.dashboardObserverRejectedFrameCount.peek()).toBe(1)
      expect(observerState.dashboardObserverLastRejectedFrameError.peek()).toEqual(expect.any(String))
      for (let i = 0; i < 5; i++) {
        source.enqueue(new TextEncoder().encode(': keepalive\n\n'))
        await vi.advanceTimersByTimeAsync(60_000)
      }
      expect(mocks.fetch).toHaveBeenCalledTimes(1)
      expect(recovery).toHaveBeenCalledTimes(1)
      expect(dashboardObserverAdmissionCount.peek()).toBe(1)
    } finally { unsubscribe() }
  })

  it('isolates a subscriber exception without reconnecting or dropping the following frame', async () => {
    mocks.fetch.mockResolvedValue(response())
    const changed = vi.fn().mockImplementationOnce(() => { throw new Error('subscriber failed') })
    const recovery = vi.fn()
    const unsubscribe = subscribeDashboardObservation({ topics: ['health'] }, changed, recovery)
    try {
      connectDashboardObserver()
      await flush()
      const valid = JSON.stringify({ type: 'workspace_dataset_changed', dataset: 'dashboard_observation',
        topic: 'health', scope: 'workspace' })
      source.enqueue(new TextEncoder().encode(`data: ${valid}\n\ndata: ${valid}\n\n`))
      await flush()
      expect(dashboardObserverReady.peek()).toBe(true)
      expect(changed).toHaveBeenCalledTimes(2)
      expect(observerState.dashboardObserverRejectedFrameCount.peek()).toBe(1)
      expect(observerState.dashboardObserverLastRejectedFrameError.peek()).toBe('subscriber failed')
      await vi.advanceTimersByTimeAsync(TRANSPORT_RETRY_BASE_MS)
      expect(mocks.fetch).toHaveBeenCalledTimes(1)
      expect(recovery).toHaveBeenCalledTimes(1)
    } finally { unsubscribe() }
  })

  it('admits an authenticated fresh stream before recovery and performs no healthy HTTP polling', async () => {
    mocks.fetch.mockResolvedValue(response())
    const order: boolean[] = []
    const unsubscribe = subscribeDashboardObservation({ topics: ['health'] }, () => {},
      () => order.push(dashboardObserverReady.peek()))
    connectDashboardObserver()
    await flush()
    expect(order).toEqual([true])
    expect(mocks.fetch).toHaveBeenCalledWith('/mcp?sse_kind=observer', expect.objectContaining({
      credentials: 'omit', headers: { Authorization: 'Bearer first', Accept: 'text/event-stream' },
    }))
    for (let i = 0; i < 5; i++) {
      source.enqueue(new TextEncoder().encode(': keepalive\n\n'))
      await vi.advanceTimersByTimeAsync(60_000)
    }
    expect(mocks.fetch).toHaveBeenCalledTimes(1)
    expect(dashboardObserverReady.peek()).toBe(true)
    unsubscribe()
  })

  it('reconnects a lost stream with a fresh snapshot boundary', async () => {
    mocks.fetch.mockImplementation(() => Promise.resolve(response()))
    connectDashboardObserver()
    await flush()
    source.close()
    await flush()
    expect(dashboardObserverReady.peek()).toBe(false)
    await vi.advanceTimersByTimeAsync(TRANSPORT_RETRY_BASE_MS)
    expect(dashboardObserverAdmissionCount.peek()).toBe(2)
    expect(mocks.fetch).toHaveBeenCalledTimes(2)
    expect(mocks.fetch.mock.calls[1]![1].headers).not.toHaveProperty('Last-Event-ID')
  })

  it('renews a rejected credential before admission and preserves the target', async () => {
    mocks.fetch.mockResolvedValueOnce(new Response('', { status: 401 })).mockResolvedValueOnce(response())
    mocks.refresh.mockImplementation(async () => { mocks.token = 'second'; return true })
    connectDashboardObserver()
    await flush()
    expect(mocks.fetch).toHaveBeenCalledTimes(2)
    expect(mocks.fetch.mock.calls[1]![0]).toBe(mocks.fetch.mock.calls[0]![0])
    expect(mocks.fetch.mock.calls[1]![1].headers.Authorization).toBe('Bearer second')
    expect(dashboardObserverReady.peek()).toBe(true)
  })

  it.each([401, 403])('keeps a persistent %s refusal stopped until credentials change', async status => {
    mocks.fetch.mockResolvedValue(new Response('', { status }))
    connectDashboardObserver()
    await flush()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(mocks.fetch).toHaveBeenCalledTimes(1)
    if (status === 403) expect(mocks.refresh).not.toHaveBeenCalled()
    mocks.fetch.mockResolvedValue(response())
    mocks.changed?.()
    await flush()
    expect(dashboardObserverReady.peek()).toBe(true)
  })

  it('does not remint again if the renewed credential is also refused', async () => {
    mocks.fetch.mockResolvedValue(new Response('', { status: 401 }))
    mocks.refresh.mockResolvedValue(true)
    connectDashboardObserver()
    await flush()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(mocks.fetch).toHaveBeenCalledTimes(2)
    expect(mocks.refresh).toHaveBeenCalledTimes(1)
  })

  it('retires the old stream on token change and ignores late payloads', async () => {
    mocks.fetch.mockImplementation(() => Promise.resolve(response()))
    connectDashboardObserver()
    await flush()
    const old = source
    mocks.changed?.()
    await flush()
    expect(() => old.enqueue(new TextEncoder().encode('data: {}\n\n'))).toThrow()
    expect(mocks.fetch).toHaveBeenCalledTimes(2)
    disconnectDashboardObserver()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(mocks.fetch).toHaveBeenCalledTimes(2)
  })

  it('keeps operation and keeper invalidations scoped to their original identities', () => {
    const matching = vi.fn(), other = vi.fn()
    const a = subscribeDashboardObservation({ topics: ['chat_operation'], keeperName: 'piano', operationId: 'original' }, matching)
    const b = subscribeDashboardObservation({ topics: ['chat_operation'], keeperName: 'piano', operationId: 'other' }, other)
    receiveDashboardObserverEvent({ type: 'workspace_dataset_changed', dataset: 'dashboard_observation',
      topic: 'chat_operation', scope: ['operation', { keeper_name: 'piano', operation_id: 'original' }] })
    expect(matching).toHaveBeenCalledTimes(1)
    expect(other).not.toHaveBeenCalled()
    expect(() => receiveDashboardObserverEvent({ type: 'workspace_dataset_changed', dataset: 'dashboard_observation',
      topic: 'chat_operation', scope: ['operation', { keeper_name: '', operation_id: 'original' }] })).toThrow()
    a(); b()
  })
})
