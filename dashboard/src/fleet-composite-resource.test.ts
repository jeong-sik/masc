import { act } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError, clearStoredToken, setStoredToken } from './api/core'
import { acceptedExecutionWorkspace } from './execution-workspace-authority'
import { acquireFleetComposite, fleetCompositeData, fleetCompositeLoading, type FleetCompositeLease } from './fleet-composite-resource'
import { publishDashboardObservationChange, publishDashboardObservationRecovery } from './lib/observation-refresh'

const leases: FleetCompositeLease[] = []
const acquire = () => { const lease = acquireFleetComposite(); leases.push(lease); return lease }
const answer = (generation: number) => Response.json({ generated_at: generation, count: 0, snapshots: [] })
const settle = () => act(async () => { await vi.advanceTimersByTimeAsync(0); await vi.dynamicImportSettled() })
function workspace(label: string) {
  acceptedExecutionWorkspace.value = { epoch: `fleet-${label}`, workspaceRoot: `/workspace-${label}`,
    connectionGeneration: 1, observerInstanceId: `fleet-instance-${label}` }
}
function pendingFetch() {
  const calls: Array<{ signal: AbortSignal; resolve: (response: Response) => void }> = []
  const fetch = vi.fn((path: string, init: RequestInit) => {
    expect(path).toBe('/api/v1/keepers/composite')
    return new Promise<Response>(resolve => { calls.push({ signal: init.signal as AbortSignal, resolve }) })
  })
  vi.stubGlobal('fetch', fetch)
  return { calls, fetch }
}
async function complete(calls: ReturnType<typeof pendingFetch>['calls'], index: number, generation: number) {
  await act(async () => { calls[index]!.resolve(answer(generation)) })
  await settle()
}

beforeEach(() => {
  vi.useFakeTimers()
  setStoredToken('shared-fleet-credential', { source: 'manual' })
  workspace('A')
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
  vi.spyOn(console, 'warn').mockImplementation(() => {})
})
afterEach(async () => {
  for (const lease of leases.splice(0)) lease.release()
  acceptedExecutionWorkspace.value = null
  clearStoredToken()
  await settle()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe('shared fleet composite actual HTTP ownership', () => {
  it('keeps an unknown owner pending with GET0 and reads once after authority is accepted', async () => {
    acceptedExecutionWorkspace.value = null
    const fetch = vi.fn(async () => answer(1))
    vi.stubGlobal('fetch', fetch)
    acquire()
    await settle()
    expect(fetch).not.toHaveBeenCalled()
    expect(fleetCompositeData.value).toBeNull()
    expect(fleetCompositeLoading.value).toBe(true)
    workspace('B')
    await settle()
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(fleetCompositeData.value?.generated_at).toBe(1)
    expect(fleetCompositeLoading.value).toBe(false)
  })
  it('joins two mounted leases into one read and does not cancel the remaining caller', async () => {
    const { calls, fetch } = pendingFetch()
    const first = acquire()
    const second = acquire()
    await settle()
    expect(fetch).toHaveBeenCalledTimes(1)
    first.release()
    expect(calls[0]!.signal.aborted).toBe(false)
    await complete(calls, 0, 1)
    expect(fleetCompositeData.value?.generated_at).toBe(1)
    second.release()
    expect(fleetCompositeData.value).toBeNull()
    publishDashboardObservationChange({ topic: 'keeper_composite' })
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  it('physically aborts the last lease and ignores a transport that returns after cancellation', async () => {
    const { calls, fetch } = pendingFetch()
    const lease = acquire()
    await settle()
    lease.release()
    expect(calls[0]!.signal.aborted).toBe(true)
    await complete(calls, 0, 1)
    expect(fleetCompositeData.value).toBeNull()
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  it('withdraws A cache while B waits and cannot re-admit it after all consumers unmount', async () => {
    const { calls } = pendingFetch()
    const lease = acquire()
    await settle()
    await complete(calls, 0, 1)
    expect(fleetCompositeData.value?.generated_at).toBe(1)
    workspace('B')
    expect(fleetCompositeData.value).toBeNull()
    await settle()
    expect(calls).toHaveLength(2)
    lease.release()
    expect(calls[1]!.signal.aborted).toBe(true)
    await complete(calls, 1, 2)
    expect(fleetCompositeData.value).toBeNull()
  })

  it('coalesces manual refresh joins into one read after an already-running read', async () => {
    const { calls } = pendingFetch()
    const first = acquire()
    const second = acquire()
    await settle()
    const one = first.refresh()
    const two = second.refresh()
    const three = first.refresh()
    let settled = false
    void one.then(() => { settled = true })
    expect(calls).toHaveLength(1)
    await complete(calls, 0, 1)
    expect(settled).toBe(false)
    expect(calls).toHaveLength(2)
    await complete(calls, 1, 2)
    expect((await Promise.all([one, two, three])).map(snapshot => snapshot.generated_at)).toEqual([2, 2, 2])
    expect(calls).toHaveLength(2)
  })

  it('settles manual read joins on last release using the active request cancellation', async () => {
    const { calls } = pendingFetch()
    const lease = acquire()
    await settle()
    const joined = lease.refresh().catch(cause => cause)
    lease.release()
    const cause = await joined
    expect(calls[0]!.signal.aborted).toBe(true)
    expect(cause).toMatchObject({ name: 'AbortError' })
    await complete(calls, 0, 1)
    expect(calls).toHaveLength(1)
  })

  it('settles only the released caller join and keeps the other consumer read alive', async () => {
    const { calls } = pendingFetch()
    const first = acquire()
    const second = acquire()
    await settle()
    const retired = first.refresh().catch(cause => cause)
    const kept = second.refresh()
    first.release()
    expect(await retired).toMatchObject({ name: 'AbortError' })
    expect(calls[0]!.signal.aborted).toBe(false)
    await complete(calls, 0, 1)
    await complete(calls, 1, 2)
    expect((await kept).generated_at).toBe(2)
  })

  it('cancels an A manual join on owner replacement and reads B without replaying any effect', async () => {
    const { calls, fetch } = pendingFetch()
    const lease = acquire()
    await settle()
    const joined = lease.refresh().catch(cause => cause)
    workspace('B')
    expect(await joined).toMatchObject({ name: 'AbortError' })
    expect(calls[0]!.signal.aborted).toBe(true)
    await settle()
    await complete(calls, 1, 2)
    await complete(calls, 0, 1)
    expect(fleetCompositeData.value?.generated_at).toBe(2)
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it.each([401, 403])('retains original HTTP %i and refuses source/focus/recovery and manual joins for that owner', async status => {
    const fetch = vi.fn(async () => Response.json({ error: 'access refused' }, { status }))
    vi.stubGlobal('fetch', fetch)
    const lease = acquire()
    await settle()
    const failure = await lease.refresh().catch(cause => cause)
    expect(failure).toBeInstanceOf(ApiRequestError)
    expect(failure.status).toBe(status)
    publishDashboardObservationChange({ topic: 'keeper_composite' })
    window.dispatchEvent(new Event('focus'))
    publishDashboardObservationRecovery()
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(fetch).toHaveBeenCalledTimes(1)
    setStoredToken('actual-new-fleet-credential', { source: 'manual' })
    await settle()
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it.each([401, 403])('settles an owed manual join if the original in-flight read receives HTTP %i', async status => {
    const { calls } = pendingFetch()
    const lease = acquire()
    await settle()
    let failure: unknown = null
    const joined = lease.refresh().catch(cause => { failure = cause; return cause })
    await act(async () => { calls[0]!.resolve(Response.json({ error: 'access refused' }, { status })) })
    await settle()
    expect(failure).toBeInstanceOf(ApiRequestError)
    expect((await joined).status).toBe(status)
    expect(calls).toHaveLength(1)
  })

  it('retains failed-read debt through a transient failure and stops retrying after success', async () => {
    const fetch = vi.fn().mockResolvedValueOnce(Response.json({ error: 'temporary failure' }, { status: 500 }))
      .mockResolvedValueOnce(answer(2))
    vi.stubGlobal('fetch', fetch)
    acquire()
    await settle()
    expect(fetch).toHaveBeenCalledTimes(1)
    await act(async () => { await vi.advanceTimersByTimeAsync(1_000) })
    await settle()
    expect(fleetCompositeData.value?.generated_at).toBe(2)
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(fetch).toHaveBeenCalledTimes(2)
  })
})
