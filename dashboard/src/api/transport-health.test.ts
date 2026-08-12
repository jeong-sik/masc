import { Effect, Option } from 'effect'
import { describe, expect, it } from 'vitest'

import {
  DashboardHttp,
  DashboardTransportError,
  type DashboardHttpService,
} from './effect-http'
import {
  fetchTransportHealth,
  TransportHealthSchemaDriftError,
} from './transport-health'

const initializingWire = {
  status: 'initializing',
  generated_at: '2026-08-12T00:00:00Z',
  message: 'Transport health data is warming up.',
  projection_diagnostics: {
    source: 'cached_surface',
    cache_state: 'initializing',
    last_success_at: null,
    last_attempt_at: null,
    last_error_at: null,
    stale_reason: null,
    stale_age_ms: null,
  },
} as const

function runWithHttp<A, E>(
  program: Effect.Effect<A, E, DashboardHttp>,
  http: DashboardHttpService,
): Effect.Effect<A, E> {
  return program.pipe(Effect.provideService(DashboardHttp, http))
}

describe('fetchTransportHealth', () => {
  it('decodes the unknown HTTP payload before exposing a domain value', () => {
    const result = Effect.runSync(
      runWithHttp(fetchTransportHealth(), {
        getUnknown: () => Effect.succeed(initializingWire),
      }),
    )

    expect('status' in result && result.status).toBe('initializing')
    expect(Option.isNone(result.projection_diagnostics.last_success_at)).toBe(
      true,
    )
  })

  it('preserves a transport failure as a typed error', () => {
    const transportError = new DashboardTransportError({
      method: 'GET',
      path: '/api/v1/dashboard/transport-health',
      message: 'network unavailable',
      cause: new Error('network unavailable'),
    })
    const error = Effect.runSync(
      Effect.flip(
        runWithHttp(fetchTransportHealth(), {
          getUnknown: () => Effect.fail(transportError),
        }),
      ),
    )

    expect(error).toBe(transportError)
  })

  it('maps an invalid HTTP payload to schema drift', () => {
    const error = Effect.runSync(
      Effect.flip(
        runWithHttp(fetchTransportHealth(), {
          getUnknown: () => Effect.succeed({ status: 'ready' }),
        }),
      ),
    )

    expect(error).toBeInstanceOf(TransportHealthSchemaDriftError)
  })
})
