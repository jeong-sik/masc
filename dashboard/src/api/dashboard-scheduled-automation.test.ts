import { describe, expect, it, vi, afterEach } from 'vitest'
import {
  fetchDashboardScheduledAutomation,
  normalizeScheduledAutomation,
} from './dashboard-scheduled-automation'

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe('normalizeScheduledAutomation', () => {
  it('keeps a schedule-store read failure reported as unknown, not as zero', () => {
    // Exactly what the owner emits when Schedule_store.read_state_result fails:
    // every count null, status unknown, the reason carried alongside.
    const normalized = normalizeScheduledAutomation({
      schema: 'masc.dashboard.scheduled_automation.v1',
      source: 'schedule_store',
      status: 'unknown',
      schedule_store_read_error: 'schedule store read failed: corrupt ledger',
      request_count: null,
      request_limit: null,
      counts: null,
      fsm: { state: 'unknown', active_count: null, terminal_count: null, next_due_at: null },
      requests: [],
      signals: [],
    })

    expect(normalized.request_count).toBeNull()
    expect(normalized.request_limit).toBeNull()
    expect(normalized.counts).toBeNull()
    expect(normalized.fsm.active_count).toBeNull()
    expect(normalized.fsm.terminal_count).toBeNull()
    expect(normalized.fsm.state).toBe('unknown')
    expect(normalized.schedule_store_read_error).toBe(
      'schedule store read failed: corrupt ledger',
    )
    // The row list is empty on a read failure, but that must not be laundered
    // into a request_count of 0.
    expect(normalized.requests).toEqual([])
  })

  it('preserves a genuine zero as zero', () => {
    const normalized = normalizeScheduledAutomation({
      status: 'idle',
      request_count: 0,
      request_limit: 20,
      counts: {},
      fsm: { state: 'idle', active_count: 0, terminal_count: 0, next_due_at: null },
      requests: [],
      signals: [],
    })

    expect(normalized.request_count).toBe(0)
    expect(normalized.counts).toEqual({})
    expect(normalized.fsm.active_count).toBe(0)
    expect(normalized.fsm.terminal_count).toBe(0)
  })

  it('carries populated counts through unchanged', () => {
    const normalized = normalizeScheduledAutomation({
      status: 'active',
      request_count: 3,
      request_limit: 20,
      truncated: true,
      counts: { scheduled: 2, due: 1, bogus: 'not-a-number' },
      fsm: { state: 'active', active_count: 3, terminal_count: 7, next_due_at: '2026-08-11T00:00:00Z' },
      requests: [{ schedule_id: 's1' }, { schedule_id: 's2' }, { schedule_id: 's3' }],
      signals: [{ schedule_id: 's1' }],
      warnings: ['late', 42],
    })

    expect(normalized.request_count).toBe(3)
    expect(normalized.truncated).toBe(true)
    // A non-numeric count is dropped rather than coerced to 0.
    expect(normalized.counts).toEqual({ scheduled: 2, due: 1 })
    expect(normalized.fsm.next_due_at).toBe('2026-08-11T00:00:00Z')
    expect(normalized.signals).toHaveLength(1)
    expect(normalized.warnings).toEqual(['late'])
  })

  it('totalizes array and object fields when the server omits them', () => {
    const normalized = normalizeScheduledAutomation({})
    expect(normalized.requests).toEqual([])
    expect(normalized.signals).toEqual([])
    expect(normalized.warnings).toEqual([])
    expect(normalized.fsm).toEqual({
      state: 'unknown',
      active_count: null,
      terminal_count: null,
      next_due_at: null,
    })
  })
})

describe('fetchDashboardScheduledAutomation', () => {
  it('requests the dedicated endpoint, not the tool inventory', async () => {
    // A fresh Response per call: a body can only be read once, and the
    // dev-token preflight consumes the first one.
    const fetchMock = vi.fn().mockImplementation(() =>
      Promise.resolve(
        new Response(JSON.stringify({ status: 'idle', request_count: 0, counts: {} }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        }),
      ),
    )
    vi.stubGlobal('fetch', fetchMock)

    await fetchDashboardScheduledAutomation()

    const requested = fetchMock.mock.calls.map(call => String(call[0]))
    expect(requested.some(url => url.includes('/api/v1/dashboard/scheduled-automation'))).toBe(true)
    expect(requested.some(url => url.includes('/api/v1/dashboard/tools'))).toBe(false)
  })
})
