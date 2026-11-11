import { act, cleanup, renderHook } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError, clearStoredToken, setStoredToken } from '../api/core'
import { fetchKeeperComposite, fetchKeeperRuntimeTrace } from '../api/keeper'
import { TRANSPORT_RETRY_MAX_MS } from '../config/constants'
import { acceptedExecutionWorkspace } from '../execution-workspace-authority'
import { publishDashboardObservationChange, publishDashboardObservationRecovery } from '../lib/observation-refresh'
import { confirmRuntimeTestWorkspace } from '../lib/runtime-workspace.test-fixture'
import { useKeeperCompositeEvidence, useKeeperRuntimeTraceEvidence } from './keeper-detail-hooks'

const reads = [
  {
    kind: 'composite',
    path: '/api/v1/keepers/alpha/composite',
    topic: 'keeper_composite',
    read: () => fetchKeeperComposite('alpha'),
  },
  {
    kind: 'trace',
    path: '/api/v1/keepers/alpha/runtime-trace?limit=200',
    topic: 'keeper_runtime_trace',
    read: () => fetchKeeperRuntimeTrace('alpha', { limit: 200 }),
  },
] as const

const settle = () => act(async () => {
  await vi.advanceTimersByTimeAsync(0)
  await vi.dynamicImportSettled()
})

beforeEach(() => {
  vi.useFakeTimers()
  setStoredToken('keeper-detail-http-a', { source: 'manual' })
  confirmRuntimeTestWorkspace()
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
  vi.spyOn(console, 'warn').mockImplementation(() => {})
})

afterEach(() => {
  cleanup()
  acceptedExecutionWorkspace.value = null
  clearStoredToken()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe.each([401, 403])('Keeper detail HTTP %s', status => {
  it.each(reads)('preserves the actual $kind method, path and refusal status', async reading => {
    const fetch = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) =>
      Response.json({ error: 'access refused' }, { status }))
    vi.stubGlobal('fetch', fetch)

    let cause: unknown
    try {
      await reading.read()
    } catch (error) {
      cause = error
    }

    expect(fetch).toHaveBeenCalledTimes(1)
    expect(fetch.mock.calls[0]![0]).toBe(reading.path)
    expect(cause).toBeInstanceOf(ApiRequestError)
    expect(cause).toMatchObject({ method: 'GET', path: reading.path, status })
  })

  it.each(reads)('keeps the mounted $kind refusal terminal until its actual token changes', async reading => {
    const fetch = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) =>
      Response.json({ error: 'access refused' }, { status }))
    vi.stubGlobal('fetch', fetch)
    const { result } = renderHook(() => reading.kind === 'composite'
      ? useKeeperCompositeEvidence('alpha')
      : useKeeperRuntimeTraceEvidence('alpha'))

    await settle()
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(result.current.kind).toBe('error')
    expect(new Headers(fetch.mock.calls[0]![1]?.headers).get('Authorization')).toBe('Bearer keeper-detail-http-a')

    publishDashboardObservationChange({ topic: reading.topic })
    publishDashboardObservationRecovery()
    window.dispatchEvent(new Event('focus'))
    await act(async () => { await vi.advanceTimersByTimeAsync(TRANSPORT_RETRY_MAX_MS * 4) })
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)

    await act(async () => { setStoredToken('keeper-detail-http-b', { source: 'manual' }) })
    await settle()
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(new Headers(fetch.mock.calls[1]![1]?.headers).get('Authorization')).toBe('Bearer keeper-detail-http-b')
    expect(result.current.kind).toBe('error')
    await act(async () => { await vi.advanceTimersByTimeAsync(TRANSPORT_RETRY_MAX_MS * 4) })
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(vi.getTimerCount()).toBe(0)
  })
})
