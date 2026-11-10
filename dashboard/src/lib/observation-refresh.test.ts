import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError, clearStoredToken, setStoredToken } from '../api/core'
import { acceptedExecutionWorkspace } from '../execution-workspace-authority'
import { createManagedAsyncResource } from './async-state'
import { confirmRuntimeTestWorkspace } from './runtime-workspace.test-fixture'
import {
  publishDashboardObservationChange,
  publishDashboardObservationRecovery,
  selectObservationReadFailure,
  setupObservationRefresh,
  ObservationPending,
  retainObservationReadFailure,
} from './observation-refresh'

const disposers: Array<() => void> = []
const flush = async () => { await Promise.resolve(); await Promise.resolve() }

beforeEach(() => {
  setStoredToken('observation-token-a', { source: 'manual' })
  confirmRuntimeTestWorkspace()
  expect(acceptedExecutionWorkspace.peek()).toEqual({
    epoch: expect.any(String), workspaceRoot: '/fixture/runtime-consumer',
    connectionGeneration: expect.any(Number),
  })
})

afterEach(() => {
  for (const dispose of disposers.splice(0)) dispose()
  acceptedExecutionWorkspace.value = null
  clearStoredToken()
  vi.restoreAllMocks()
  vi.useRealTimers()
})

describe('authoritative observation reads', () => {
  it.each([
    () => new ObservationPending('projection is initializing'),
    () => retainObservationReadFailure(new Error('store owns failed read debt')),
  ])('waits for its producer or store recovery without a duplicate retry timer', async failure => {
    vi.useFakeTimers()
    const read = vi.fn(async () => { throw failure() })
    disposers.push(setupObservationRefresh(read, { topics: ['keeper_composite'] }))
    await flush()
    await vi.advanceTimersByTimeAsync(300_000)
    expect(read).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
    publishDashboardObservationChange({ topic: 'keeper_composite' })
    await flush()
    expect(read).toHaveBeenCalledTimes(2)
  })

  it('preserves a trailing invalidation received during a pending read', async () => {
    let finish!: () => void
    const read = vi.fn(async () => {
      if (read.mock.calls.length === 1) {
        await new Promise<void>(resolve => { finish = resolve })
        throw new ObservationPending('producer is pending')
      }
    })
    disposers.push(setupObservationRefresh(read, { topics: ['keeper_composite'] }))
    await flush()
    publishDashboardObservationChange({ topic: 'keeper_composite' })
    finish()
    await flush(); await flush()
    expect(read).toHaveBeenCalledTimes(2)
  })

  it('preserves a combined read refusal ahead of a transient sibling failure', () => {
    const transient = new Error('temporary failure')
    const refused = new ApiRequestError({ method: 'GET', path: '/fixture', status: 403 })
    expect(selectObservationReadFailure([transient, null, refused])).toBe(refused)
    expect(selectObservationReadFailure([undefined, transient])).toBe(transient)
    expect(selectObservationReadFailure([null, undefined])).toBeNull()
  })

  it('reads initially and after a matching change, without periodic HTTP', async () => {
    vi.useFakeTimers()
    const read = vi.fn(async () => ({ state: 'ready' }))
    disposers.push(setupObservationRefresh(read, { topics: ['health'] }))
    await flush()
    expect(read).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(180_000)
    expect(read).toHaveBeenCalledTimes(1)
    publishDashboardObservationChange({ topic: 'logs' })
    await flush()
    expect(read).toHaveBeenCalledTimes(1)
    publishDashboardObservationChange({ topic: 'health' })
    await flush()
    expect(read).toHaveBeenCalledTimes(2)
  })

  it('preserves one trailing authoritative read for a burst during a slow read', async () => {
    let finish!: () => void
    let current = 'before'
    let observed = ''
    const read = vi.fn(async () => {
      const value = current
      if (read.mock.calls.length === 1) await new Promise<void>(resolve => { finish = resolve })
      observed = value
    })
    disposers.push(setupObservationRefresh(read, { topics: ['verification_requests'] }))
    await flush()
    current = 'after'
    publishDashboardObservationChange({ topic: 'verification_requests' })
    publishDashboardObservationChange({ topic: 'verification_requests' })
    expect(read).toHaveBeenCalledTimes(1)
    finish()
    await flush()
    await flush()
    expect(read).toHaveBeenCalledTimes(2)
    expect(observed).toBe('after')
  })

  it('limits a scoped chat observation to its original operation', async () => {
    const read = vi.fn(async () => {})
    disposers.push(setupObservationRefresh(read, {
      topics: ['chat_operation'], keeperName: 'alpha', operationId: 'original',
    }))
    await flush()
    publishDashboardObservationChange({ topic: 'chat_operation', keeperName: 'beta', operationId: 'original' })
    publishDashboardObservationChange({ topic: 'chat_operation', keeperName: 'alpha', operationId: 'other' })
    await flush()
    expect(read).toHaveBeenCalledTimes(1)
    publishDashboardObservationChange({ topic: 'chat_operation', keeperName: 'alpha', operationId: 'original' })
    await flush()
    expect(read).toHaveBeenCalledTimes(2)
  })

  it('remembers hidden invalidation and coalesces visibility with focus', async () => {
    let visibility: DocumentVisibilityState = 'hidden'
    vi.spyOn(document, 'visibilityState', 'get').mockImplementation(() => visibility)
    const read = vi.fn(async () => {})
    disposers.push(setupObservationRefresh(read, { topics: ['tools'] }))
    publishDashboardObservationChange({ topic: 'tools' })
    await flush()
    expect(read).not.toHaveBeenCalled()
    visibility = 'visible'
    document.dispatchEvent(new Event('visibilitychange'))
    window.dispatchEvent(new Event('focus'))
    await flush()
    expect(read).toHaveBeenCalledTimes(1)
  })

  it('starts the recovered read before the retired read settles', async () => {
    let finish!: () => void
    const signals: AbortSignal[] = []
    const read = vi.fn(async (signal: AbortSignal) => {
      signals.push(signal)
      if (signals.length === 1) await new Promise<void>(resolve => { finish = resolve })
    })
    disposers.push(setupObservationRefresh(read, { topics: ['runtime_probe'] }))
    await flush()
    publishDashboardObservationRecovery()
    expect(signals[0]!.aborted).toBe(true)
    await flush()
    expect(read).toHaveBeenCalledTimes(2)
    expect(signals[1]!.aborted).toBe(false)
    finish()
    await flush()
    expect(read).toHaveBeenCalledTimes(2)
  })

  it('withdraws the old workspace result and ignores its late completion', async () => {
    const reads: Array<{ signal: AbortSignal; finish: (value: string) => void }> = []
    let evidence: string | null = 'retained from an earlier mount'
    const read = (signal: AbortSignal) => new Promise<string>(finish => {
      reads.push({ signal, finish })
    }).then(value => { if (!signal.aborted) evidence = value })
    disposers.push(setupObservationRefresh(read, {
      topics: ['keeper_composite'], resetRead: () => { evidence = null },
    }))
    expect(evidence).toBeNull()
    await flush()
    reads[0]!.finish('workspace A')
    await flush(); await flush()
    expect(evidence).toBe('workspace A')
    publishDashboardObservationChange({ topic: 'keeper_composite' })
    await flush()
    acceptedExecutionWorkspace.value = Object.freeze({ epoch: 'workspace-b', workspaceRoot: '/workspace-b',
      connectionGeneration: 1 })
    expect(evidence).toBeNull()
    expect(reads[1]!.signal.aborted).toBe(true)
    await flush()
    reads[2]!.finish('workspace B')
    await flush(); await flush()
    reads[1]!.finish('late workspace A')
    await flush(); await flush()
    expect(evidence).toBe('workspace B')
  })

  it.each([401, 403])('keeps HTTP %i refused until the credential owner changes', async status => {
    vi.useFakeTimers()
    let failure: unknown | null = new ApiRequestError({ method: 'GET', path: '/fixture', status })
    const read = vi.fn(async () => {})
    disposers.push(setupObservationRefresh(read, {
      topics: ['health'], readError: () => failure, onError: () => {},
    }))
    await flush()
    publishDashboardObservationChange({ topic: 'health' })
    publishDashboardObservationRecovery()
    window.dispatchEvent(new Event('focus'))
    await vi.advanceTimersByTimeAsync(180_000)
    expect(read).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
    failure = null
    setStoredToken('observation-token-b', { source: 'manual' })
    await flush()
    expect(read).toHaveBeenCalledTimes(2)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('waits without HTTP or a timer while the workspace has no accepted identity', async () => {
    vi.useFakeTimers()
    acceptedExecutionWorkspace.value = null
    const read = vi.fn(async () => {})
    disposers.push(setupObservationRefresh(read, { topics: ['health'] }))
    publishDashboardObservationRecovery()
    await vi.advanceTimersByTimeAsync(180_000)
    expect(read).not.toHaveBeenCalled()
    expect(vi.getTimerCount()).toBe(0)
    confirmRuntimeTestWorkspace()
    await flush()
    expect(read).toHaveBeenCalledTimes(1)
  })

  it('retires resource-owned I/O and refuses its body after disposal', async () => {
    const resource = createManagedAsyncResource<string>()
    let signal!: AbortSignal
    let finish!: (value: string) => void
    const dispose = setupObservationRefresh(() => resource.load(readSignal => {
      signal = readSignal
      return new Promise<string>(resolve => { finish = resolve })
    }), { topics: ['tools'], cancelRead: () => resource.cancel() })
    disposers.push(dispose)
    await flush()
    dispose()
    expect(signal.aborted).toBe(true)
    finish('retired body')
    await flush(); await flush()
    expect(resource.state.peek().data).toBeNull()
  })

  it('repays a failed initial read once and leaves no timer after success', async () => {
    vi.useFakeTimers()
    const read = vi.fn().mockRejectedValueOnce(new Error('HTTP 500')).mockResolvedValue(undefined)
    const onError = vi.fn()
    disposers.push(setupObservationRefresh(read, { topics: ['health'], onError }))
    await flush()
    expect(onError).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(1)
    publishDashboardObservationChange({ topic: 'health' })
    publishDashboardObservationChange({ topic: 'health' })
    await flush()
    expect(read).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1_000)
    expect(read).toHaveBeenCalledTimes(2)
    expect(vi.getTimerCount()).toBe(0)
    await vi.advanceTimersByTimeAsync(180_000)
    expect(read).toHaveBeenCalledTimes(2)
  })

  it('retains state-backed failure and cancels its retry when authority recovers', async () => {
    vi.useFakeTimers()
    let resourceError: string | null = 'HTTP 503'
    const read = vi.fn(async () => {})
    const dispose = setupObservationRefresh(read, {
      topics: ['tools'], readError: () => resourceError, onError: () => {},
    })
    disposers.push(dispose)
    await flush()
    expect(vi.getTimerCount()).toBe(1)
    resourceError = null
    publishDashboardObservationRecovery()
    await flush()
    expect(read).toHaveBeenCalledTimes(2)
    expect(vi.getTimerCount()).toBe(0)
    resourceError = 'HTTP 500'
    publishDashboardObservationChange({ topic: 'tools' })
    await flush()
    expect(vi.getTimerCount()).toBe(1)
    dispose()
    expect(vi.getTimerCount()).toBe(0)
  })

  it('stops trailing reads and listeners when the surface unmounts', async () => {
    let finish!: () => void
    const read = vi.fn(() => new Promise<void>(resolve => { finish = resolve }))
    const dispose = setupObservationRefresh(read, { topics: ['logs'] })
    await flush()
    publishDashboardObservationChange({ topic: 'logs' })
    dispose()
    finish()
    window.dispatchEvent(new Event('focus'))
    publishDashboardObservationRecovery()
    await flush()
    expect(read).toHaveBeenCalledTimes(1)
  })
})
