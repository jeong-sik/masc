import { Effect } from 'effect'
import { describe, expect, it } from 'vitest'

import {
  DashboardHttp,
  DashboardTransportError,
  type DashboardHttpService,
} from './effect-http'
import {
  fetchFeatureHealth,
  FeatureHealthSchemaDriftError,
} from './feature-health'

const currentWire = {
  generated_at: 1_786_500_000.25,
  overview: {
    total_features: 0,
    healthy_count: 0,
    warning_count: 0,
    inactive_count: 0,
    enabled_count: 0,
    overridden_count: 0,
  },
  features_by_category: {},
  all_features: [],
} as const

function runWithHttp<A, E>(
  program: Effect.Effect<A, E, DashboardHttp>,
  http: DashboardHttpService,
): Effect.Effect<A, E> {
  return program.pipe(Effect.provideService(DashboardHttp, http))
}

describe('fetchFeatureHealth', () => {
  it('decodes the unknown HTTP payload before exposing a domain value', () => {
    const data = Effect.runSync(
      runWithHttp(fetchFeatureHealth(), {
        getUnknown: path => {
          expect(path).toBe('/api/v1/dashboard/feature-health')
          return Effect.succeed(currentWire)
        },
      }),
    )

    expect(data.overview.total_features).toBe(0)
  })

  it('preserves a transport failure as a typed error', () => {
    const transportError = new DashboardTransportError({
      method: 'GET',
      path: '/api/v1/dashboard/feature-health',
      message: 'network unavailable',
      cause: new Error('network unavailable'),
    })
    const error = Effect.runSync(
      Effect.flip(
        runWithHttp(fetchFeatureHealth(), {
          getUnknown: () => Effect.fail(transportError),
        }),
      ),
    )

    expect(error).toBe(transportError)
  })

  it('maps an invalid HTTP payload to schema drift', () => {
    const error = Effect.runSync(
      Effect.flip(
        runWithHttp(fetchFeatureHealth(), {
          getUnknown: () => Effect.succeed({ generated_at: 'now' }),
        }),
      ),
    )

    expect(error).toBeInstanceOf(FeatureHealthSchemaDriftError)
  })
})
