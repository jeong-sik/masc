import { act, cleanup, renderHook, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { fetchKeeperComposite, fetchKeeperRuntimeTrace } from '../api/keeper'
import { clearStoredToken, setStoredToken } from '../api/core'
import { acceptedExecutionWorkspace } from '../execution-workspace-authority'
import { TRANSPORT_RETRY_BASE_MS } from '../config/constants'
import { publishDashboardObservationRecovery } from '../lib/observation-refresh'
import { confirmRuntimeTestWorkspace } from '../lib/runtime-workspace.test-fixture'
import { useKeeperCompositeEvidence, useKeeperRuntimeTraceEvidence } from './keeper-detail-hooks'

vi.mock('../api/keeper', () => ({
  fetchKeeperComposite: vi.fn(),
  fetchKeeperRuntimeTrace: vi.fn(),
}))

beforeEach(() => {
  setStoredToken('detail-observation-a', { source: 'manual' })
  confirmRuntimeTestWorkspace()
})

afterEach(() => {
  cleanup()
  acceptedExecutionWorkspace.value = null
  clearStoredToken()
  vi.resetAllMocks()
  vi.restoreAllMocks()
  vi.useRealTimers()
})

describe('Keeper detail observation ownership', () => {
  it('aborts the actual API signal and refuses a late result across recovery', async () => {
    const fetch = vi.mocked(fetchKeeperComposite)
    const first = {} as Awaited<ReturnType<typeof fetchKeeperComposite>>
    const current = {} as Awaited<ReturnType<typeof fetchKeeperComposite>>
    let finish!: (value: typeof first) => void
    fetch.mockImplementationOnce(() => new Promise(resolve => { finish = resolve }))
      .mockResolvedValue(current)
    const { result } = renderHook(() => useKeeperCompositeEvidence('alpha'))
    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1))
    const signal = fetch.mock.calls[0]![1]!.signal!
    act(() => publishDashboardObservationRecovery())
    expect(signal.aborted).toBe(true)
    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(2))
    await act(async () => { finish(first); await Promise.resolve() })
    await waitFor(() => expect(result.current.kind).toBe('fresh'))
    if (result.current.kind === 'fresh') expect(result.current.data).toBe(current)
  })

  it('withdraws the previous owner evidence before a new credential read settles', async () => {
    const fetch = vi.mocked(fetchKeeperComposite)
    const first = {} as Awaited<ReturnType<typeof fetchKeeperComposite>>
    fetch.mockResolvedValueOnce(first).mockImplementation(() => new Promise(() => {}))
    const { result } = renderHook(() => useKeeperCompositeEvidence('alpha'))
    await waitFor(() => expect(result.current.kind).toBe('fresh'))
    act(() => setStoredToken('detail-observation-b', { source: 'manual' }))
    expect(result.current.kind).toBe('loading')
    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(2))
    expect(result.current.kind).toBe('loading')
  })

  it('reports trace failure and retries on a quiet stream', async () => {
    const fetch = vi.mocked(fetchKeeperRuntimeTrace)
    const current = {} as Awaited<ReturnType<typeof fetchKeeperRuntimeTrace>>
    let fail!: (reason: unknown) => void
    fetch.mockImplementationOnce(() => new Promise((_, reject) => { fail = reject }))
      .mockResolvedValue(current)
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    const { result } = renderHook(() => useKeeperRuntimeTraceEvidence('alpha'))
    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1))
    vi.useFakeTimers()
    await act(async () => { fail(new Error('temporary failure')); await Promise.resolve() })
    expect(result.current.kind).toBe('error')
    await act(async () => { await vi.advanceTimersByTimeAsync(TRANSPORT_RETRY_BASE_MS) })
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(result.current.kind).toBe('fresh')
    if (result.current.kind === 'fresh') expect(result.current.data).toBe(current)
  })
})
