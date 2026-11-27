import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { DashboardScheduledAutomationRequest } from '../api'
import type { DashboardScheduledAutomationProjection } from '../api/dashboard-scheduled-automation'
import { publishDashboardObservationChange } from '../lib/observation-refresh'
import { confirmRuntimeTestWorkspace } from '../lib/runtime-workspace.test-fixture'
import { KeeperScheduleList, byNextWake, lastWakeMs, nextWakeText } from './keeper-schedule-list'

type FetchKeeperSchedules = (
  keeperName: string,
  opts?: { signal?: AbortSignal },
) => Promise<DashboardScheduledAutomationProjection>

// Mocked once for the file: the panel's module graph is heavy, and importing it
// again for every test is slow enough to run into the test timeout.
const fetchSchedules = vi.hoisted(() => vi.fn<FetchKeeperSchedules>())
vi.mock('../api/dashboard-scheduled-automation', async importOriginal => ({
  ...(await importOriginal<typeof import('../api/dashboard-scheduled-automation')>()),
  fetchKeeperScheduledAutomation: fetchSchedules,
}))

const HOUR_MS = 3_600_000
// 2026-11-27T12:00:00Z
const NOW_MS = Date.UTC(2026, 10, 27, 12, 0, 0)

function req(
  scheduleId: string,
  fields: Partial<DashboardScheduledAutomationRequest> = {},
): DashboardScheduledAutomationRequest {
  return { schedule_id: scheduleId, status: 'scheduled', source: 'operator', ...fields }
}

const at = (ms: number) => ({ next_due_at: ms / 1000 })

describe('byNextWake', () => {
  it('puts the earliest next run first and schedules that will not run again last', () => {
    const rows = [
      req('later', at(NOW_MS + 3 * HOUR_MS)),
      // An ended one-shot keeps its due time; it is not a next run.
      req('ended', { status: 'succeeded', due_at: (NOW_MS + HOUR_MS) / 1000, next_due_at: null }),
      req('soon', at(NOW_MS + HOUR_MS)),
      req('due', at(NOW_MS - HOUR_MS)),
      req('cancelled', { status: 'cancelled' }),
    ]

    expect(byNextWake(rows).map(row => row.schedule_id))
      .toEqual(['due', 'soon', 'later', 'ended', 'cancelled'])
  })

  it('reads the ISO next run before the epoch seconds', () => {
    const rows = [
      req('iso-late', { next_due_at_iso: new Date(NOW_MS + 2 * HOUR_MS).toISOString(), next_due_at: 0 }),
      req('epoch', at(NOW_MS + HOUR_MS)),
    ]

    expect(byNextWake(rows).map(row => row.schedule_id)).toEqual(['epoch', 'iso-late'])
  })
})

describe('nextWakeText', () => {
  it('says when there is no next run', () => {
    expect(nextWakeText(req('ended', { status: 'succeeded', next_due_at: null }), NOW_MS)).toBe('다음 실행 없음')
  })

  // The server names no next wake while a wake is being dispatched,
  // recurring schedules included.
  it('says a schedule whose wake is being dispatched is running', () => {
    expect(nextWakeText(req('daily', { status: 'running', next_due_at: null }), NOW_MS)).toBe('실행 중')
  })

  it('carries the time until a next run that is still to come', () => {
    expect(nextWakeText(req('a', at(NOW_MS + 2 * HOUR_MS)), NOW_MS)).toMatch(/ \(2시간 후\)$/)
  })

  it('carries the time since a next run that is already due', () => {
    expect(nextWakeText(req('a', at(NOW_MS - 3 * HOUR_MS)), NOW_MS)).toMatch(/ \(3시간 전\)$/)
  })

  it('counts whole seconds within the last minute', () => {
    expect(nextWakeText(req('a', at(NOW_MS + 12_345.6)), NOW_MS)).toMatch(/ \(12초 후\)$/)
  })
})

describe('lastWakeMs', () => {
  it('takes when the last wake ended, else when it started', () => {
    const ended = req('a', { last_wake: { schedule_id: 'a', status: 'ok', started_at: 100, finished_at: 160 } })
    const running = req('b', { last_wake: { schedule_id: 'b', status: 'running', started_at: 100, finished_at: null } })

    expect(lastWakeMs(ended)).toBe(160_000)
    expect(lastWakeMs(running)).toBe(100_000)
    expect(lastWakeMs(req('c'))).toBeNull()
  })
})

function page(requests: DashboardScheduledAutomationRequest[]): DashboardScheduledAutomationProjection {
  return {
    state: 'available',
    data: {
      status: 'ok',
      schedule_store_known: true,
      schedule_store_read_error: null,
      request_count: requests.length,
      request_limit: 200,
      truncated: false,
      counts: { scheduled: requests.length },
      fsm: { state: 'active', active_count: requests.length, terminal_count: 0 },
      requests,
    },
    page: { visibleCount: requests.length, totalCount: requests.length, limit: 200, truncated: false },
  }
}

async function flushUi(): Promise<void> {
  await act(async () => {
    for (let i = 0; i < 4; i += 1) {
      await Promise.resolve()
      await vi.advanceTimersByTimeAsync(0)
    }
  })
}

describe('KeeperScheduleList', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(NOW_MS)
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    fetchSchedules.mockReset()
    vi.useRealTimers()
  })

  async function draw(answer: DashboardScheduledAutomationProjection, keeperName: string) {
    fetchSchedules.mockImplementation(() => Promise.resolve(answer))
    // Each draw reads under a workspace of its own.
    confirmRuntimeTestWorkspace()
    await act(async () => {
      render(html`<${KeeperScheduleList} keeperName=${keeperName} />`, container)
      await Promise.resolve()
    })
    await flushUi()
  }

  const state = () => container.querySelector('[data-keeper-schedules]')?.getAttribute('data-keeper-schedules') ?? null
  const rowIds = () => Array.from(
    container.querySelectorAll('[data-testid="keeper-schedule-row"]'),
    row => row.getAttribute('data-schedule-id'),
  )

  it('reads the Keeper’s schedules and lists them by next run, each opening its schedule', async () => {
    await draw(page([
      req('nightly', { ...at(NOW_MS + 10 * HOUR_MS), payload_summary: '밤 정리' }),
      req('poll', { ...at(NOW_MS + 2 * HOUR_MS), payload_summary: '큐 확인' }),
    ]), 'alpha')

    expect(fetchSchedules).toHaveBeenCalledTimes(1)
    expect(fetchSchedules.mock.calls[0]?.[0]).toBe('alpha')
    expect(state()).toBe('available')
    expect(rowIds()).toEqual(['poll', 'nightly'])
    const first = container.querySelector<HTMLAnchorElement>('[data-testid="keeper-schedule-row"]')
    expect(first?.getAttribute('href')).toContain('schedule_id=poll')
    expect(first?.textContent).toContain('큐 확인')
    // The shared clock was read when its module loaded; its next tick reads
    // the test's clock.
    await act(async () => { await vi.advanceTimersByTimeAsync(5_000) })
    expect(container.querySelector('[data-testid="keeper-schedule-next"]')?.textContent).toMatch(/\(2시간 후\)$/)
  })

  it('reads again when a schedule changes', async () => {
    await draw(page([]), 'alpha')
    expect(fetchSchedules).toHaveBeenCalledTimes(1)

    await act(async () => { publishDashboardObservationChange({ topic: 'scheduled_automation' }) })
    await flushUi()

    expect(fetchSchedules).toHaveBeenCalledTimes(2)
  })

  it('marks a next run that is already due and says when the page was cut', async () => {
    const answer = page([
      req('due', at(NOW_MS - HOUR_MS)),
      req('soon', at(NOW_MS + 2 * HOUR_MS)),
    ])
    if (answer.state !== 'available') throw new Error('fixture page is available')
    await draw({ ...answer, page: { ...answer.page, truncated: true } }, 'alpha')
    // Whether a run is due is read against the shared clock, which reads the
    // test's clock from its next tick on.
    await act(async () => { await vi.advanceTimersByTimeAsync(5_000) })

    const overdue = Array.from(
      container.querySelectorAll('[data-testid="keeper-schedule-next"]'),
      next => next.getAttribute('data-overdue'),
    )
    expect(rowIds()).toEqual(['due', 'soon'])
    expect(overdue).toEqual(['true', 'false'])
    expect(container.textContent).toContain('앞 2개만 읽었어요.')
  })

  it('says the Keeper has no schedule apart from a page it could not read', async () => {
    await draw(page([]), 'alpha')
    expect(container.textContent).toContain('이 Keeper 를 깨우는 예약이 없어요.')

    render(null, container)
    await draw({ state: 'unavailable', reason: 'corrupt ledger' }, 'alpha')
    expect(state()).toBe('unavailable')
    expect(container.textContent).toContain('예약을 읽지 못했어요: corrupt ledger')
    expect(rowIds()).toEqual([])
  })

  it('shows the refresh failure alongside the empty state when a re-read fails after an empty page', async () => {
    await draw(page([]), 'alpha')
    expect(container.textContent).toContain('이 Keeper 를 깨우는 예약이 없어요.')
    expect(container.textContent).not.toContain('마지막 새로고침 실패:')

    fetchSchedules.mockRejectedValueOnce(new Error('503 service unavailable'))
    await act(async () => { publishDashboardObservationChange({ topic: 'scheduled_automation' }) })
    await flushUi()

    expect(fetchSchedules).toHaveBeenCalledTimes(2)
    expect(state()).toBe('available')
    expect(container.textContent).toContain('이 Keeper 를 깨우는 예약이 없어요.')
    expect(container.textContent).toContain('마지막 새로고침 실패: 503 service unavailable')
    expect(rowIds()).toEqual([])
  })
})
