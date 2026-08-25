import { describe, expect, it, vi, afterEach } from 'vitest'
import {
  decodeScheduledAutomationLookup,
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
    // every ledger count null, status unknown, the reason carried alongside.
    const normalized = normalizeScheduledAutomation({
      schema: 'masc.dashboard.scheduled_automation.v1',
      source: 'schedule_store',
      status: 'unknown',
      schedule_store_known: false,
      schedule_store_read_error: 'schedule store read failed: corrupt ledger',
      request_count: null,
      request_limit: 20,
      truncated: false,
      counts: null,
      fsm: { state: 'unknown', active_count: null, terminal_count: null, next_due_at: null },
      requests: [],
      signals: [],
    })

    expect(normalized).toEqual({
      state: 'unavailable',
      reason: 'schedule store read failed: corrupt ledger',
    })
  })

  it('preserves a genuine zero as zero', () => {
    const normalized = normalizeScheduledAutomation({
      status: 'ok',
      schedule_store_known: true,
      schedule_store_read_error: null,
      request_count: 0,
      request_limit: 20,
      truncated: false,
      counts: {},
      fsm: { state: 'idle', active_count: 0, terminal_count: 0, next_due_at: null },
      requests: [],
      signals: [],
    })

    expect(normalized.state).toBe('available')
    if (normalized.state !== 'available') throw new Error(normalized.reason)
    expect(normalized.data.request_count).toBe(0)
    expect(normalized.data.counts).toEqual({})
    expect(normalized.data.fsm.active_count).toBe(0)
    expect(normalized.data.fsm.terminal_count).toBe(0)
    expect(normalized.page).toEqual({
      visibleCount: 0,
      totalCount: 0,
      limit: 20,
      truncated: false,
    })
  })

  it('carries populated counts through unchanged', () => {
    const normalized = normalizeScheduledAutomation({
      status: 'ok',
      schedule_store_known: true,
      schedule_store_read_error: null,
      request_count: 3,
      request_limit: 20,
      truncated: true,
      counts: { scheduled: 2, due: 1, bogus: 'not-a-number' },
      fsm: { state: 'active', active_count: 3, terminal_count: 7, next_due_at: '2026-08-11T00:00:00Z' },
      requests: [{ schedule_id: 's1' }, { schedule_id: 's2' }, { schedule_id: 's3' }],
      signals: [{ schedule_id: 's1' }],
      warnings: ['late', 42],
    })

    expect(normalized.state).toBe('available')
    if (normalized.state !== 'available') throw new Error(normalized.reason)
    expect(normalized.data.request_count).toBe(3)
    expect(normalized.data.truncated).toBe(true)
    // A non-numeric count is dropped rather than coerced to 0.
    expect(normalized.data.counts).toEqual({ scheduled: 2, due: 1 })
    expect(normalized.data.fsm.next_due_at).toBe('2026-08-11T00:00:00Z')
    expect(normalized.data.signals).toHaveLength(1)
    expect(normalized.data.warnings).toEqual(['late'])
    expect(normalized.page).toEqual({
      visibleCount: 3,
      totalCount: 3,
      limit: 20,
      truncated: true,
    })
  })

  it('fails closed when required ledger fields are omitted', () => {
    const normalized = normalizeScheduledAutomation({})
    expect(normalized).toEqual({
      state: 'unavailable',
      reason: 'schedule ledger projection is incomplete',
    })
  })

  it('does not infer a healthy zero from null counts even without an error string', () => {
    const normalized = normalizeScheduledAutomation({
      status: 'ok',
      schedule_store_known: true,
      request_count: null,
      request_limit: 20,
      truncated: false,
      counts: null,
      fsm: { state: 'unknown', active_count: null, terminal_count: null },
      requests: [],
    })

    expect(normalized.state).toBe('unavailable')
  })
})

describe('decodeScheduledAutomationLookup', () => {
  it('accepts the owner envelope and keeps the exact request identity', () => {
    const decoded = decodeScheduledAutomationLookup({
      schema: 'masc.dashboard.scheduled_automation.lookup.v1',
      source: 'schedule_store',
      generated_at: '2026-08-14T00:00:00Z',
      status: 'found',
      schedule_id: 'sched-exact',
      request: {
        schedule_id: 'sched-exact',
        status: 'due',
        source: 'operator_request',
        payload_kind: 'keeper.review',
      },
    }, 'sched-exact')

    expect(decoded).toEqual({
      status: 'found',
      scheduleId: 'sched-exact',
      request: {
        schedule_id: 'sched-exact',
        status: 'due',
        source: 'operator_request',
        payload_kind: 'keeper.review',
      },
    })
  })

  it('rejects a request row that does not belong to the requested identity', () => {
    expect(() => decodeScheduledAutomationLookup({
      schema: 'masc.dashboard.scheduled_automation.lookup.v1',
      source: 'schedule_store',
      generated_at: '2026-08-14T00:00:00Z',
      status: 'found',
      schedule_id: 'sched-exact',
      request: {
        schedule_id: 'sched-other',
        status: 'due',
        source: 'operator_request',
      },
    }, 'sched-exact')).toThrow('request identity mismatch')
  })

  it('rejects an envelope returned for a different route identity', () => {
    expect(() => decodeScheduledAutomationLookup({
      schema: 'masc.dashboard.scheduled_automation.lookup.v1',
      source: 'schedule_store',
      generated_at: '2026-08-14T00:00:00Z',
      status: 'not_found',
      schedule_id: 'sched-other',
    }, 'sched-exact')).toThrow('envelope identity mismatch')
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
