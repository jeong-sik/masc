import { Effect } from 'effect'
import { describe, expect, it } from 'vitest'

import {
  DashboardHttp,
  DashboardTransportError,
  type DashboardHttpService,
} from './effect-http'
import {
  fetchGateKeepers,
  GateKeepersSchemaDriftError,
} from './gate-keepers'

const currentWire = {
  count: 1,
  keepers: [{
    runtime_class: 'keeper',
    name: 'planner',
    meta: {
      name: 'planner',
      trace_id: 'trace-planner',
      created_at: '2026-08-12T00:00:00Z',
      updated_at: '2026-08-12T00:01:00Z',
    },
    status: 'running',
    phase: 'active',
    health: 'healthy',
    paused: false,
    next_action: null,
    keepalive_running: true,
    autoboot_enabled: true,
    proactive_enabled: false,
    runtime_id: 'runtime-planner',
    created_at: '2026-08-12T00:00:00Z',
    updated_at: '2026-08-12T00:01:00Z',
  }],
  total: 1,
  limit: 200,
  truncated: false,
} as const

function runWithHttp<A, E>(
  program: Effect.Effect<A, E, DashboardHttp>,
  http: DashboardHttpService,
): Effect.Effect<A, E> {
  return program.pipe(Effect.provideService(DashboardHttp, http))
}

describe('fetchGateKeepers', () => {
  it('fetches and decodes unknown data at the typed endpoint boundary', () => {
    const data = Effect.runSync(runWithHttp(fetchGateKeepers(), {
      getUnknown: path => {
        expect(path).toBe('/api/v1/gate/keepers?detailed=true')
        return Effect.succeed(currentWire)
      },
    }))

    expect(data.keepers[0]?.name).toBe('planner')
    expect(data.listing).toEqual({ total: 1, limit: 200, truncated: false })
  })

  it('does not pin a limit — the route bounds itself and reports the bound', () => {
    // masc#29077: a limit hardcoded here was a second cap the UI had to keep in
    // sync with the route, and it lost that race (50 vs a 200 clamp).
    Effect.runSync(runWithHttp(fetchGateKeepers(), {
      getUnknown: path => {
        expect(path).not.toContain('limit=')
        return Effect.succeed(currentWire)
      },
    }))
  })

  it('carries the truncation verdict through to the product value', () => {
    const truncatedWire = { ...currentWire, total: 129, limit: 50, truncated: true }
    const data = Effect.runSync(runWithHttp(fetchGateKeepers(), {
      getUnknown: () => Effect.succeed(truncatedWire),
    }))

    expect(data.listing.truncated).toBe(true)
    expect(data.listing.total).toBe(129)
    // The rows are the page, not the directory. A consumer that reads
    // keepers.length as the keeper count is the bug this field exists for.
    expect(data.keepers.length).toBe(1)
  })

  it('rejects a response that omits the listing fields', () => {
    // Strict decoding, so a server that stops sending them is drift rather
    // than a silent downgrade to the old "count is all there is" shape.
    const { total: _total, ...withoutTotal } = currentWire
    const error = Effect.runSync(Effect.flip(runWithHttp(
      fetchGateKeepers(),
      { getUnknown: () => Effect.succeed(withoutTotal) },
    )))

    expect(error).toBeInstanceOf(GateKeepersSchemaDriftError)
  })

  it('preserves transport failures as typed values', () => {
    const transportError = new DashboardTransportError({
      method: 'GET',
      path: '/api/v1/gate/keepers?detailed=true',
      message: 'offline',
      cause: new Error('offline'),
    })
    const error = Effect.runSync(Effect.flip(runWithHttp(
      fetchGateKeepers(),
      { getUnknown: () => Effect.fail(transportError) },
    )))

    expect(error).toBe(transportError)
  })

  it('preserves schema drift as a typed endpoint error', () => {
    const error = Effect.runSync(Effect.flip(runWithHttp(
      fetchGateKeepers(),
      { getUnknown: () => Effect.succeed({ count: 1, keepers: [] }) },
    )))

    expect(error).toBeInstanceOf(GateKeepersSchemaDriftError)
  })
})
