import { Effect } from 'effect'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError, clearStoredToken, setStoredToken } from './api/core'
import { decodeLogsStreamFrame, type LogsStreamFrame } from './api/schemas/logs'
import { logStreamWire } from './test-support/logs-stream-fixture'

const { read, recoverToken } = vi.hoisted(() => ({ read: vi.fn(), recoverToken: vi.fn(async () => false) }))
vi.mock('./api/dashboard-logs-stream', async original => ({
  ...await original<typeof import('./api/dashboard-logs-stream')>(), readDashboardLogsStream: read,
}))
vi.mock('./api/dev-token', () => ({ refreshDevTokenAfterAuthError: recoverToken, ensureDevToken: vi.fn(async () => {}) }))

import { subscribeDashboardLogsStream } from './dashboard-logs-stream'
import { publishDashboardObservationRecovery } from './lib/observation-refresh'

const disposers: Array<() => void> = []
const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve() }
const frame = (seqs: readonly number[], reset = true) => Effect.runSync(decodeLogsStreamFrame(logStreamWire(seqs, reset)))
afterEach(() => {
  for (const dispose of disposers.splice(0)) dispose()
  read.mockReset(); recoverToken.mockReset().mockResolvedValue(false)
  clearStoredToken(); vi.useRealTimers()
})

describe('shared native log stream', () => {
  it('shares one query stream, appends without HTTP, replays state and releases the last owner', async () => {
    vi.useFakeTimers()
    let emit!: (frame: LogsStreamFrame) => void
    let signal!: AbortSignal
    read.mockImplementation((_request, received, apply) => { signal = received; emit = apply; return new Promise(() => {}) })
    const first = vi.fn(), second = vi.fn()
    const a = subscribeDashboardLogsStream({ limit: 200 }, { onFrame: first, onError: vi.fn(), onReset: vi.fn() })
    disposers.push(a)
    await flush()
    emit(frame([3, 2])); emit(frame([4], false))
    const b = subscribeDashboardLogsStream({ limit: 200 }, { onFrame: second, onError: vi.fn(), onReset: vi.fn() })
    disposers.push(b)
    expect(second.mock.calls[0]?.[0].data.entries.map((entry: { seq: number }) => entry.seq)).toEqual([4, 3, 2])
    await vi.advanceTimersByTimeAsync(120_000)
    expect(read).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
    a(); expect(signal.aborted).toBe(false)
    b(); expect(signal.aborted).toBe(true)
  })

  it('recovers transport failure with its cursor and withdraws it when credentials change', async () => {
    vi.useFakeTimers()
    let reject!: (error: unknown) => void
    const emits: Array<(frame: LogsStreamFrame) => void> = []
    const signals: AbortSignal[] = []
    read.mockImplementation((_request, signal, apply) => {
      signals.push(signal); emits.push(apply)
      return new Promise((_resolve, refuse) => { reject = refuse })
    })
    const apply = vi.fn(), reset = vi.fn()
    disposers.push(subscribeDashboardLogsStream({}, { onFrame: apply, onError: vi.fn(), onReset: reset }))
    await flush()
    emits[0]!(frame([4]))
    reject(new Error('socket lost'))
    await flush()
    expect(vi.getTimerCount()).toBe(1)
    await vi.advanceTimersByTimeAsync(1_000)
    expect(read.mock.calls[1]?.[0]).toEqual({ sinceSeq: 4 })
    setStoredToken('new-log-reader', { source: 'manual' })
    await flush()
    expect(signals[1]?.aborted).toBe(true)
    expect(read.mock.calls[2]?.[0]).toEqual({ sinceSeq: undefined })
    emits[1]!(frame([99]))
    expect(apply).toHaveBeenCalledTimes(1)
    emits[2]!(frame([1]))
    expect(apply).toHaveBeenCalledTimes(2)
    expect(reset).toHaveBeenCalledTimes(2)
  })

  it('reopens once after a 401 replaces a managed token', async () => {
    vi.useFakeTimers()
    read.mockRejectedValueOnce(new ApiRequestError({ method: 'GET', path: '/api/v1/dashboard/logs/stream',
      status: 401, authErrorCode: 'token_expired' }))
      .mockImplementation(() => new Promise(() => {}))
    recoverToken.mockImplementationOnce(async () => {
      setStoredToken('fresh-managed-log-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
      return true
    })
    disposers.push(subscribeDashboardLogsStream({}, { onFrame: vi.fn(), onError: vi.fn(), onReset: vi.fn() }))
    await flush()
    expect(recoverToken).toHaveBeenCalledWith('token_expired')
    expect(read).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(120_000)
    expect(read).toHaveBeenCalledTimes(2)
    expect(vi.getTimerCount()).toBe(0)
  })

  it.each([401, 403])('leaves a %s refusal unavailable without retrying the refused credential', async status => {
    vi.useFakeTimers()
    read.mockRejectedValue(new ApiRequestError({ method: 'GET', path: '/api/v1/dashboard/logs/stream', status }))
    const unavailable = vi.fn()
    disposers.push(subscribeDashboardLogsStream({}, { onFrame: vi.fn(), onError: unavailable, onReset: vi.fn() }))
    await flush()
    await vi.advanceTimersByTimeAsync(120_000)
    publishDashboardObservationRecovery()
    window.dispatchEvent(new Event('focus')); window.dispatchEvent(new Event('online'))
    await flush()
    expect(read).toHaveBeenCalledTimes(1)
    expect(unavailable).toHaveBeenCalledTimes(1)
    expect(recoverToken).toHaveBeenCalledTimes(status === 401 ? 1 : 0)
    expect(vi.getTimerCount()).toBe(0)
  })
})
