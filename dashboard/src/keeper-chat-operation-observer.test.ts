import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { KeeperChatOperation, KeeperChatOperationState } from './api/keeper'
import { acceptedExecutionWorkspace } from './execution-workspace-authority'

const { read } = vi.hoisted(() => ({ read: vi.fn() }))
vi.mock('./api/keeper', () => ({ fetchKeeperChatOperation: read }))

import { observeKeeperChatOperation, waitForKeeperChatOperationTerminal } from './keeper-chat-operation-observer'
import { publishDashboardObservationChange, publishDashboardObservationRecovery } from './lib/observation-refresh'

const disposers: Array<() => void> = []
const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve() }
const operation = (state: KeeperChatOperationState): KeeperChatOperation => ({
  operationId: 'original', sequence: '1', createdAt: 1, input: null, state,
})
beforeEach(() => {
  acceptedExecutionWorkspace.value = { epoch: 'operation-test', workspaceRoot: '/fixture/operation',
    connectionGeneration: 1, observerInstanceId: 'operation-test-instance' }
})
afterEach(() => {
  for (const dispose of disposers.splice(0)) dispose()
  read.mockReset()
  vi.restoreAllMocks()
  vi.useRealTimers()
})

describe('durable original-operation observation', () => {
  it('reads once while queued, then settles only on the original operation change', async () => {
    vi.useFakeTimers()
    read.mockResolvedValueOnce(operation({ kind: 'queued' }))
      .mockResolvedValueOnce(operation({ kind: 'succeeded', completedAt: 2, outcomeRef: 'receipt' }))
    const pending = vi.fn()
    const waiter = waitForKeeperChatOperationTerminal('alpha', 'original', { onPending: pending })
    disposers.push(waiter.dispose)
    await flush()
    expect(pending).toHaveBeenCalledTimes(1)
    expect(read).toHaveBeenCalledWith('alpha', 'original', { signal: expect.any(AbortSignal) })
    await vi.advanceTimersByTimeAsync(60_000)
    publishDashboardObservationChange({ topic: 'chat_operation', keeperName: 'beta', operationId: 'original' })
    publishDashboardObservationChange({ topic: 'chat_operation', keeperName: 'alpha', operationId: 'different' })
    await flush()
    expect(read).toHaveBeenCalledTimes(1)
    publishDashboardObservationChange({ topic: 'chat_operation', keeperName: 'alpha', operationId: 'original' })
    expect((await waiter.result).state.kind).toBe('succeeded')
    expect(read).toHaveBeenCalledTimes(2)
    publishDashboardObservationRecovery()
    await vi.advanceTimersByTimeAsync(60_000)
    expect(read).toHaveBeenCalledTimes(2)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('coalesces a burst crossing the initial read into one terminal read', async () => {
    let finish!: (value: KeeperChatOperation) => void
    read.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
      .mockResolvedValueOnce(operation({ kind: 'cancelled', completedAt: 3 }))
    const waiter = waitForKeeperChatOperationTerminal('alpha', 'original')
    disposers.push(waiter.dispose)
    await flush()
    for (let i = 0; i < 4; i++) {
      publishDashboardObservationChange({ topic: 'chat_operation', keeperName: 'alpha', operationId: 'original' })
    }
    expect(read).toHaveBeenCalledTimes(1)
    finish(operation({ kind: 'running', startedAt: 2 }))
    expect((await waiter.result).state.kind).toBe('cancelled')
    expect(read).toHaveBeenCalledTimes(2)
  })

  it('retains failed-read debt while an observer owns it and stops after a successful read', async () => {
    vi.useFakeTimers()
    const observed = vi.fn()
    read.mockRejectedValueOnce(new Error('HTTP 503')).mockResolvedValue(operation({ kind: 'queued' }))
    disposers.push(observeKeeperChatOperation('alpha', 'original', { onOperation: observed }))
    await flush()
    expect(vi.getTimerCount()).toBe(1)
    await vi.advanceTimersByTimeAsync(1_000)
    expect(observed).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
    await vi.advanceTimersByTimeAsync(60_000)
    expect(read).toHaveBeenCalledTimes(2)
  })

  it('retains the lookup failure boundary without leaving a second retry owner', async () => {
    vi.useFakeTimers()
    read.mockRejectedValueOnce(new Error('lookup unavailable'))
    const waiter = waitForKeeperChatOperationTerminal('alpha', 'original')
    await expect(waiter.result).rejects.toThrow('lookup unavailable')
    expect(vi.getTimerCount()).toBe(0)
  })

  it('retires the old authority before a reconnect can query another workspace', async () => {
    read.mockResolvedValue(operation({ kind: 'queued' }))
    let current = true
    const waiter = waitForKeeperChatOperationTerminal('alpha', 'original', { current: () => current })
    disposers.push(waiter.dispose)
    await flush()
    current = false
    publishDashboardObservationRecovery()
    await expect(waiter.result).rejects.toMatchObject({ name: 'AbortError' })
    expect(read).toHaveBeenCalledTimes(1)
  })
})
