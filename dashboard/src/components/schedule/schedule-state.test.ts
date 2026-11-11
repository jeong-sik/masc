import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { DashboardScheduledAutomationProjection } from '../../api'
import { confirmRuntimeTestWorkspace } from '../../lib/runtime-workspace.test-fixture'
import { acceptedExecutionWorkspace } from '../../execution-workspace-authority'
import { TRANSPORT_RETRY_BASE_MS } from '../../config/constants'

const mocks = vi.hoisted(() => ({
  fetchDashboardScheduledAutomation: vi.fn(),
}))

vi.mock('../../api/dashboard-scheduled-automation', () => ({
  fetchDashboardScheduledAutomation: mocks.fetchDashboardScheduledAutomation,
}))

import {
  subscribeScheduledAutomationRefresh,
  loadScheduledAutomation,
  scheduledAutomationProjection,
  scheduledAutomationError,
} from './schedule-state'

function emptyProjection(): DashboardScheduledAutomationProjection {
  return {
    state: 'available',
    data: {
      status: 'ok',
      schedule_store_known: true,
      schedule_store_read_error: null,
      request_count: 0,
      request_limit: 20,
      truncated: false,
      counts: {},
      fsm: {
        state: 'idle',
        active_count: 0,
        terminal_count: 0,
        next_due_at: null,
      },
      requests: [],
    },
    page: {
      visibleCount: 0,
      totalCount: 0,
      limit: 20,
      truncated: false,
    },
  }
}

import { publishDashboardObservationChange } from '../../lib/observation-refresh'

describe('scheduled automation refresh', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    confirmRuntimeTestWorkspace()
    mocks.fetchDashboardScheduledAutomation.mockReset()
  })

  afterEach(() => {
    acceptedExecutionWorkspace.value = null
    vi.clearAllTimers()
    vi.restoreAllMocks()
    vi.useRealTimers()
  })

  it('retires pending and queued reads before reading a new confirmed workspace', async () => {
    let finishFirst!: (projection: DashboardScheduledAutomationProjection) => void
    let finishSecond!: (projection: DashboardScheduledAutomationProjection) => void
    let firstSignal!: AbortSignal
    mocks.fetchDashboardScheduledAutomation
      .mockImplementationOnce(({ signal }: { signal: AbortSignal }) => {
        firstSignal = signal
        return new Promise(resolve => { finishFirst = resolve })
      })
      .mockImplementationOnce(() => new Promise(resolve => { finishSecond = resolve }))
    const stop = subscribeScheduledAutomationRefresh()
    try {
      await vi.advanceTimersByTimeAsync(0)
      const queued = loadScheduledAutomation({ fresh: true })
      confirmRuntimeTestWorkspace()
      await vi.advanceTimersByTimeAsync(0)
      expect(firstSignal.aborted).toBe(true)
      expect(mocks.fetchDashboardScheduledAutomation).toHaveBeenCalledTimes(2)
      finishFirst(emptyProjection())
      await queued
      await vi.advanceTimersByTimeAsync(0)
      expect(mocks.fetchDashboardScheduledAutomation).toHaveBeenCalledTimes(2)
      expect(scheduledAutomationProjection.value).toBeNull()
      finishSecond(emptyProjection())
      await vi.advanceTimersByTimeAsync(0)
      expect(scheduledAutomationProjection.value?.state).toBe('available')
    } finally { stop() }
  })

  it('retries a failed final schedule read without another source event', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    mocks.fetchDashboardScheduledAutomation.mockRejectedValueOnce(new Error('offline'))
      .mockResolvedValue(emptyProjection())
    const stop = subscribeScheduledAutomationRefresh()
    try {
      await vi.advanceTimersByTimeAsync(0)
      expect(scheduledAutomationError.value).not.toBeNull()
      await vi.advanceTimersByTimeAsync(TRANSPORT_RETRY_BASE_MS)
      expect(mocks.fetchDashboardScheduledAutomation).toHaveBeenCalledTimes(2)
      expect(scheduledAutomationError.value).toBeNull()
      expect(scheduledAutomationProjection.value?.state).toBe('available')
    } finally { stop() }
  })

  it('keeps a pending read alive and retains a trailing read for committed schedule changes', async () => {
    let resolveFirst!: (projection: DashboardScheduledAutomationProjection) => void
    let firstSignal: AbortSignal | undefined
    mocks.fetchDashboardScheduledAutomation
      .mockImplementationOnce(({ signal }: { signal?: AbortSignal }) => {
        firstSignal = signal
        return new Promise<DashboardScheduledAutomationProjection>(resolve => { resolveFirst = resolve })
      })
      .mockResolvedValue(emptyProjection())
    const stop = subscribeScheduledAutomationRefresh()
    try {
      await Promise.resolve()
      expect(mocks.fetchDashboardScheduledAutomation).toHaveBeenCalledTimes(1)
      await vi.advanceTimersByTimeAsync(35_000)
      expect(mocks.fetchDashboardScheduledAutomation).toHaveBeenCalledTimes(1)
      expect(firstSignal?.aborted).toBe(false)
      publishDashboardObservationChange({ topic: 'scheduled_automation' })
      publishDashboardObservationChange({ topic: 'scheduled_automation' })
      expect(mocks.fetchDashboardScheduledAutomation).toHaveBeenCalledTimes(1)
      resolveFirst(emptyProjection())
      await vi.waitFor(() => expect(mocks.fetchDashboardScheduledAutomation).toHaveBeenCalledTimes(2))
      expect(firstSignal?.aborted).toBe(false)
      await vi.advanceTimersByTimeAsync(60_000)
      expect(mocks.fetchDashboardScheduledAutomation).toHaveBeenCalledTimes(2)
    } finally { stop() }
  })
})
