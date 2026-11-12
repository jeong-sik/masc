import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('./sse-store', () => ({ routeServerPushEvent: vi.fn() }))
vi.mock('./sse', () => ({ recordServerPushEvent: vi.fn() }))

import { getStoredToken } from './api/core'
import { devTokenBootstrapStatus, installRejectedCredentialRecovery, resetDevTokenBootstrap } from './api/dev-token'
import { connectDashboardObserver, disconnectDashboardObserver } from './dashboard-observer'
import { dashboardObserverReady } from './dashboard-observer-state'
import { resetDashboardSessionActorForTests } from './lib/dashboard-session-actor'

const flush = async () => { for (let i = 0; i < 30; i++) await Promise.resolve() }
const tokenPath = '/api/v1/dashboard/dev-token'
let stopRecovery: () => void
let source: ReadableStreamDefaultController<Uint8Array>
function stream(): Response {
  return new Response(new ReadableStream<Uint8Array>({ start(controller) { source = controller } }), {
    headers: { 'content-type': 'text/event-stream', 'x-masc-sse-instance-id': 'process.workspace-epoch',
      'x-masc-sse-replay': 'fresh', 'x-masc-sse-idle-timeout-ms': '90000' },
  })
}
function tokenResponse(): Response {
  return new Response(JSON.stringify({ token: 'admitted', actor: 'dashboard', role: 'admin' }), {
    headers: { 'content-type': 'application/json' },
  })
}

beforeEach(() => {
  vi.useFakeTimers()
  window.sessionStorage.clear()
  resetDashboardSessionActorForTests()
  resetDevTokenBootstrap()
  stopRecovery = installRejectedCredentialRecovery()
})
afterEach(() => {
  disconnectDashboardObserver()
  stopRecovery()
  vi.unstubAllGlobals()
  vi.useRealTimers()
  window.sessionStorage.clear()
})

describe('bootstrap read and the actual observer owner', () => {
  it('joins the token installation once and keeps the admitted stream free of status reads', async () => {
    const fetch = vi.fn(async (path: string) => path === tokenPath ? tokenResponse() : stream())
    vi.stubGlobal('fetch', fetch)
    connectDashboardObserver()
    await flush()
    expect(fetch.mock.calls.map(([path]) => path)).toEqual([tokenPath, '/mcp?sse_kind=observer'])
    expect(getStoredToken()).toBe('admitted')
    expect(dashboardObserverReady.peek()).toBe(true)
    for (let i = 0; i < 5; i++) {
      source.enqueue(new TextEncoder().encode(': keepalive\n\n'))
      await vi.advanceTimersByTimeAsync(60_000)
    }
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it('keeps actual unavailable read debt beyond ten attempts and honors Retry-After', async () => {
    let tokenReads = 0
    const fetch = vi.fn(async (path: string, init?: RequestInit) => {
      if (path === tokenPath) {
        tokenReads++
        return tokenReads <= 12
          ? new Response('', { status: 503, headers: { 'retry-after': tokenReads === 1 ? '10' : '1' } })
          : tokenResponse()
      }
      return new Headers(init?.headers).has('authorization') ? stream() : new Response('', { status: 401 })
    })
    vi.stubGlobal('fetch', fetch)
    connectDashboardObserver()
    await flush()
    expect(tokenReads).toBe(1)
    await vi.advanceTimersByTimeAsync(9_999)
    expect(tokenReads).toBe(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(tokenReads).toBe(2)
    for (let i = 0; i < 12; i++) await vi.advanceTimersByTimeAsync(30_000)
    expect(tokenReads).toBe(13)
    expect(getStoredToken()).toBe('admitted')
    expect(dashboardObserverReady.peek()).toBe(true)
    disconnectDashboardObserver()
    stopRecovery()
    const stopped = fetch.mock.calls.length
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(stopped)
  })

  it('aborts the original bootstrap request when its last owner is removed', async () => {
    const signals: AbortSignal[] = []
    const fetch = vi.fn((_path: string, init?: RequestInit) => new Promise<Response>((_resolve, reject) => {
      if (init?.signal) {
        signals.push(init.signal)
        init.signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')), { once: true })
      }
    }))
    vi.stubGlobal('fetch', fetch)
    connectDashboardObserver()
    await flush()
    disconnectDashboardObserver()
    stopRecovery()
    await flush()
    expect(signals[0]?.aborted).toBe(true)
    expect(devTokenBootstrapStatus.peek()).toBe('idle')
    await vi.advanceTimersByTimeAsync(300_000)
    expect(fetch).toHaveBeenCalledTimes(1)
  })
})
