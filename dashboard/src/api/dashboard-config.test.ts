import { Effect } from 'effect'
import { describe, expect, it } from 'vitest'

import {
  DashboardHttp,
  DashboardTransportError,
  type DashboardHttpService,
} from './effect-http'
import {
  DashboardConfigSchemaDriftError,
  fetchDashboardConfig,
} from './dashboard-config'

const currentWire = {
  generated_at: '2026-08-12T00:00:00Z',
  server: {
    version: '0.42.0',
    git_commit: null,
    ocaml_version: '5.4.0',
    uptime_seconds: 10,
    pid: 42,
  },
  categories: {},
} as const

function runWithHttp<A, E>(
  program: Effect.Effect<A, E, DashboardHttp>,
  http: DashboardHttpService,
): Effect.Effect<A, E> {
  return program.pipe(Effect.provideService(DashboardHttp, http))
}

describe('fetchDashboardConfig', () => {
  it('fetches and decodes unknown config data at the typed boundary', () => {
    const data = Effect.runSync(runWithHttp(fetchDashboardConfig(), {
      getUnknown: path => {
        expect(path).toBe('/api/v1/dashboard/config')
        return Effect.succeed(currentWire)
      },
    }))

    expect(data.server.version).toBe('0.42.0')
  })

  it('preserves transport failures as typed values', () => {
    const transportError = new DashboardTransportError({
      method: 'GET',
      path: '/api/v1/dashboard/config',
      message: 'offline',
      cause: new Error('offline'),
    })
    const error = Effect.runSync(Effect.flip(runWithHttp(
      fetchDashboardConfig(),
      { getUnknown: () => Effect.fail(transportError) },
    )))

    expect(error).toBe(transportError)
  })

  it('maps malformed payloads to config drift', () => {
    const error = Effect.runSync(Effect.flip(runWithHttp(
      fetchDashboardConfig(),
      { getUnknown: () => Effect.succeed({ generated_at: 'now' }) },
    )))

    expect(error).toBeInstanceOf(DashboardConfigSchemaDriftError)
  })
})
