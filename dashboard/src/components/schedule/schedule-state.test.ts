import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { DashboardScheduledAutomationProjection } from '../../api'

const mocks = vi.hoisted(() => ({
  fetchDashboardScheduledAutomation: vi.fn(),
}))

vi.mock('../../api/dashboard-scheduled-automation', () => ({
  fetchDashboardScheduledAutomation: mocks.fetchDashboardScheduledAutomation,
}))

import {
  SCHEDULED_AUTOMATION_REFRESH_MS,
  subscribeScheduledAutomationRefresh,
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

describe('scheduled automation refresh', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    mocks.fetchDashboardScheduledAutomation.mockReset()
  })

  afterEach(() => {
    vi.clearAllTimers()
    vi.useRealTimers()
  })

  it('keeps a 35s request alive across 15s polling ticks and starts the next request later', async () => {
    let resolveFirst!: (projection: DashboardScheduledAutomationProjection) => void
    let firstSignal: AbortSignal | undefined
    mocks.fetchDashboardScheduledAutomation
      .mockImplementationOnce(({ signal }: { signal?: AbortSignal }) => {
        firstSignal = signal
        return new Promise<DashboardScheduledAutomationProjection>((resolve) => {
          resolveFirst = resolve
        })
      })
      .mockResolvedValue(emptyProjection())

    const stop = subscribeScheduledAutomationRefresh()
    try {
      expect(mocks.fetchDashboardScheduledAutomation).toHaveBeenCalledTimes(1)

      await vi.advanceTimersByTimeAsync(SCHEDULED_AUTOMATION_REFRESH_MS * 2)
      expect(mocks.fetchDashboardScheduledAutomation).toHaveBeenCalledTimes(1)
      expect(firstSignal?.aborted).toBe(false)

      await vi.advanceTimersByTimeAsync(5_000)
      resolveFirst(emptyProjection())
      await Promise.resolve()
      await Promise.resolve()

      await vi.advanceTimersByTimeAsync(10_000)
      expect(mocks.fetchDashboardScheduledAutomation).toHaveBeenCalledTimes(2)
      expect(firstSignal?.aborted).toBe(false)
    } finally {
      stop()
    }
  })
})
