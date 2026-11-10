import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { DashboardScheduledAutomationProjection } from '../../api'
import { confirmRuntimeTestWorkspace } from '../../lib/runtime-workspace.test-fixture'
import { acceptedExecutionWorkspace } from '../../execution-workspace-authority'

const mocks = vi.hoisted(() => ({
  fetchDashboardScheduledAutomation: vi.fn(),
}))

vi.mock('../../api/dashboard-scheduled-automation', () => ({
  fetchDashboardScheduledAutomation: mocks.fetchDashboardScheduledAutomation,
}))

import {
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
    vi.useRealTimers()
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
