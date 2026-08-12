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
    agent_name: 'keeper-planner-agent',
    status: 'running',
    keepalive_running: true,
    autoboot_enabled: true,
    proactive_enabled: false,
    runtime_id: 'runtime-planner',
    created_at: '2026-08-12T00:00:00Z',
    updated_at: '2026-08-12T00:01:00Z',
  }],
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
        expect(path).toBe('/api/v1/gate/keepers?limit=50&detailed=true')
        return Effect.succeed(currentWire)
      },
    }))

    expect(data.keepers[0]?.name).toBe('planner')
  })

  it('preserves transport failures as typed values', () => {
    const transportError = new DashboardTransportError({
      method: 'GET',
      path: '/api/v1/gate/keepers?limit=50&detailed=true',
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
