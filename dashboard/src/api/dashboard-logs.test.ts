import { Effect } from 'effect'
import { describe, expect, it } from 'vitest'

import {
  DashboardHttp,
  DashboardTransportError,
  type DashboardHttpService,
} from './effect-http'
import { fetchLogs, LogsSchemaDriftError } from './dashboard-logs'

const currentWire = {
  generated_at_iso: '2026-08-12T00:00:00Z',
  dashboard_surface: '/api/v1/dashboard/logs',
  source: 'masc_log_ring',
  retention: {
    scope: 'dashboard_logs',
    workspace_root: '/workspace/.masc',
    buffer: 'Log.Ring',
    capacity: 50000,
    durable_store: '/workspace/.masc/logs/system_log_2026-08-12.jsonl',
    file_pattern: 'system_log_YYYY-MM-DD.jsonl',
    keep_days: 7,
    cache_policy: 'uncached',
  },
  query: {
    limit: 200,
    level: 'INFO',
    applied_level: 'INFO',
    min_level: 1,
    module: '',
    since_seq: null,
    before_seq: null,
    category: null,
    exclude_category: null,
  },
  returned: 0,
  latest_seq: null,
  oldest_seq: null,
  latest_ts_iso: null,
  ring: { start_seq: 0, total: 0, dropped_before: false },
  total: 0,
  entries: [],
} as const

function runWithHttp<A, E>(
  program: Effect.Effect<A, E, DashboardHttp>,
  http: DashboardHttpService,
): Effect.Effect<A, E> {
  return program.pipe(Effect.provideService(DashboardHttp, http))
}

describe('fetchLogs', () => {
  it('maps the product request to the current query wire and decodes once', () => {
    const data = Effect.runSync(runWithHttp(fetchLogs({
      limit: 200,
      level: 'INFO',
      sinceSeq: 10,
      beforeSeq: 20,
      category: 'tool',
      excludeCategories: ['fsm', 'routine'],
    }), {
      getUnknown: path => {
        const [, query = ''] = path.split('?')
        const params = new URLSearchParams(query)
        expect(path.startsWith('/api/v1/dashboard/logs?')).toBe(true)
        expect(params.get('limit')).toBe('200')
        expect(params.get('level')).toBe('INFO')
        expect(params.get('since_seq')).toBe('10')
        expect(params.get('before_seq')).toBe('20')
        expect(params.get('category')).toBe('tool')
        expect(params.get('exclude_category')).toBe('fsm,routine')
        return Effect.succeed(currentWire)
      },
    }))

    expect(data.entries).toEqual([])
  })

  it('omits negative cursors instead of emitting invalid query state', () => {
    Effect.runSync(runWithHttp(fetchLogs({ beforeSeq: -1 }), {
      getUnknown: path => {
        expect(path).toBe('/api/v1/dashboard/logs')
        return Effect.succeed(currentWire)
      },
    }))
  })

  it('preserves transport failures as typed values', () => {
    const transportError = new DashboardTransportError({
      method: 'GET',
      path: '/api/v1/dashboard/logs',
      message: 'offline',
      cause: new Error('offline'),
    })
    const error = Effect.runSync(Effect.flip(runWithHttp(
      fetchLogs(),
      { getUnknown: () => Effect.fail(transportError) },
    )))

    expect(error).toBe(transportError)
  })

  it('maps malformed payloads to logs drift', () => {
    const error = Effect.runSync(Effect.flip(runWithHttp(
      fetchLogs(),
      { getUnknown: () => Effect.succeed({ total: 0, entries: [] }) },
    )))

    expect(error).toBeInstanceOf(LogsSchemaDriftError)
  })
})
