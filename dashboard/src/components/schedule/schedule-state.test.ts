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
  activeScheduleRead,
  subscribeActiveSchedulesRefresh,
  subscribeScheduledAutomationRefresh,
  loadScheduledAutomation,
  scheduledAutomationProjection,
  scheduledAutomationError,
  scheduledAutomationLoading,
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

// #52961: the calendar draws the schedules that are still going to run. That
// is another page of the same route, with its own reader.
describe('active schedules refresh', () => {
  const activeOnlyOf = (call: unknown[]) =>
    (call[0] as { activeOnly?: boolean } | undefined)?.activeOnly === true

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

  it('asks for the active-only page and reads it again on a schedule change', async () => {
    mocks.fetchDashboardScheduledAutomation.mockResolvedValue(emptyProjection())
    const stop = subscribeActiveSchedulesRefresh()
    try {
      await vi.advanceTimersByTimeAsync(0)
      expect(mocks.fetchDashboardScheduledAutomation.mock.calls.map(activeOnlyOf)).toEqual([true])
      expect(activeScheduleRead.value.observation?.projection.state).toBe('available')

      publishDashboardObservationChange({ topic: 'scheduled_automation' })
      await vi.advanceTimersByTimeAsync(0)
      expect(mocks.fetchDashboardScheduledAutomation.mock.calls.map(activeOnlyOf)).toEqual([true, true])
    } finally { stop() }
  })

  it('is read by its own subscribers only, and the fleet page by its own', async () => {
    mocks.fetchDashboardScheduledAutomation.mockResolvedValue(emptyProjection())
    const stopFleet = subscribeScheduledAutomationRefresh()
    try {
      await vi.advanceTimersByTimeAsync(0)
      publishDashboardObservationChange({ topic: 'scheduled_automation' })
      await vi.advanceTimersByTimeAsync(0)
      // Nobody has the calendar open: no active-only read.
      expect(mocks.fetchDashboardScheduledAutomation.mock.calls.map(activeOnlyOf)).toEqual([false, false])

      const stopActive = subscribeActiveSchedulesRefresh()
      try {
        await vi.advanceTimersByTimeAsync(0)
        expect(mocks.fetchDashboardScheduledAutomation.mock.calls.map(activeOnlyOf))
          .toEqual([false, false, true])
      } finally { stopActive() }

      // The calendar closed: a change is read by the fleet page alone again.
      publishDashboardObservationChange({ topic: 'scheduled_automation' })
      await vi.advanceTimersByTimeAsync(0)
      expect(mocks.fetchDashboardScheduledAutomation.mock.calls.map(activeOnlyOf))
        .toEqual([false, false, true, false])
    } finally { stopFleet() }
  })

  it('holds no page once the calendar has closed', async () => {
    let finish!: (projection: DashboardScheduledAutomationProjection) => void
    mocks.fetchDashboardScheduledAutomation.mockResolvedValueOnce(emptyProjection())
      .mockImplementationOnce(() => new Promise(resolve => { finish = resolve }))
    const stopFirst = subscribeActiveSchedulesRefresh()
    await vi.advanceTimersByTimeAsync(0)
    expect(activeScheduleRead.value.observation?.projection.state).toBe('available')
    stopFirst()
    // A calendar that opens again draws once before it subscribes. The page
    // read while it was last open is not there to be drawn as now.
    expect(activeScheduleRead.value.observation).toBeNull()

    const stopSecond = subscribeActiveSchedulesRefresh()
    try {
      await vi.advanceTimersByTimeAsync(0)
      expect(activeScheduleRead.value.observation).toBeNull()
      finish(emptyProjection())
      await vi.advanceTimersByTimeAsync(0)
      expect(activeScheduleRead.value.observation?.projection.state).toBe('available')
    } finally { stopSecond() }
  })

  // Both pages come from one kind of reader; the fleet page is the one whose
  // loading state is exported.
  it('drops the read that was on the wire when the last surface closed', async () => {
    let finish!: (projection: DashboardScheduledAutomationProjection) => void
    let readSignal!: AbortSignal
    mocks.fetchDashboardScheduledAutomation.mockImplementationOnce(({ signal }: { signal: AbortSignal }) => {
      readSignal = signal
      return new Promise(resolve => { finish = resolve })
    })
    const stop = subscribeScheduledAutomationRefresh()
    await vi.advanceTimersByTimeAsync(0)
    expect(scheduledAutomationLoading.value).toBe(true)
    stop()

    expect(readSignal.aborted).toBe(true)
    expect(scheduledAutomationLoading.value).toBe(false)
    // Its answer arrives after the close and is not kept.
    finish(emptyProjection())
    await vi.advanceTimersByTimeAsync(0)
    expect(scheduledAutomationProjection.value).toBeNull()
  })

  it('keeps the page while another surface still reads it', async () => {
    mocks.fetchDashboardScheduledAutomation.mockResolvedValue(emptyProjection())
    const stopFirst = subscribeScheduledAutomationRefresh()
    const stopSecond = subscribeScheduledAutomationRefresh()
    try {
      await vi.advanceTimersByTimeAsync(0)
      expect(scheduledAutomationProjection.value?.state).toBe('available')
      stopFirst()
      expect(scheduledAutomationProjection.value?.state).toBe('available')
    } finally { stopSecond() }
    expect(scheduledAutomationProjection.value).toBeNull()
  })
})
