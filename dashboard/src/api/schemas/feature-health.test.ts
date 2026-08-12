import { Effect } from 'effect'
import { describe, expect, it } from 'vitest'

import {
  decodeFeatureHealthData,
  FeatureHealthSchemaDriftError,
} from './feature-health'

function currentWire(source: 'env' | 'boot_override' | 'default' = 'env') {
  const feature = {
    env_name: 'MASC_GRPC_ENABLED',
    description: 'gRPC transport server',
    category: 'transport',
    lifecycle: 'active',
    is_enabled: true,
    source,
    status: 'healthy',
  } as const
  return {
    generated_at: 1_786_500_000.25,
    overview: {
      total_features: 1,
      healthy_count: 1,
      warning_count: 0,
      inactive_count: 0,
      enabled_count: 1,
      overridden_count: source === 'env' ? 1 : 0,
    },
    features_by_category: {
      transport: {
        total: 1,
        enabled: 1,
        features: [feature],
      },
    },
    all_features: [feature],
  }
}

function expectDrift(value: unknown): FeatureHealthSchemaDriftError {
  const error = Effect.runSync(Effect.flip(decodeFeatureHealthData(value)))
  expect(error).toBeInstanceOf(FeatureHealthSchemaDriftError)
  expect(error.message).toContain('feature-health schema drift')
  return error
}

describe('decodeFeatureHealthData', () => {
  it('decodes the complete current producer contract', () => {
    const data = Effect.runSync(decodeFeatureHealthData(currentWire()))

    expect(data.overview.total_features).toBe(1)
    expect(data.features_by_category.transport?.features[0]?.status).toBe(
      'healthy',
    )
    expect(data.all_features[0]?.env_name).toBe('MASC_GRPC_ENABLED')
  })

  it.each(['env', 'boot_override', 'default'] as const)(
    'accepts the current %s source variant',
    source => {
      const data = Effect.runSync(decodeFeatureHealthData(currentWire(source)))
      expect(data.all_features[0]?.source).toBe(source)
    },
  )

  it.each([
    ['negative count', {
      ...currentWire(),
      overview: { ...currentWire().overview, total_features: -1 },
    }],
    ['fractional count', {
      ...currentWire(),
      overview: { ...currentWire().overview, total_features: 1.5 },
    }],
    ['non-finite timestamp', {
      ...currentWire(),
      generated_at: Number.POSITIVE_INFINITY,
    }],
    ['unknown lifecycle', {
      ...currentWire(),
      all_features: [
        { ...currentWire().all_features[0], lifecycle: 'deprecated' },
      ],
    }],
    ['unknown source', {
      ...currentWire(),
      all_features: [
        { ...currentWire().all_features[0], source: 'config_file' },
      ],
    }],
    ['unknown status', {
      ...currentWire(),
      all_features: [
        { ...currentWire().all_features[0], status: 'degraded' },
      ],
    }],
    ['contradictory active status', {
      ...currentWire(),
      all_features: [
        { ...currentWire().all_features[0], status: 'inactive' },
      ],
    }],
    ['excess property', {
      ...currentWire(),
      legacy_status: 'ok',
    }],
  ])('rejects %s', (_name, value) => {
    expectDrift(value)
  })

  it('rejects overview counts that disagree with the feature domain', () => {
    const error = expectDrift({
      ...currentWire(),
      overview: { ...currentWire().overview, healthy_count: 0 },
    })

    expect(error.message).toContain('overview.healthy_count')
  })

  it('rejects category projections that do not partition all_features', () => {
    const error = expectDrift({
      ...currentWire(),
      features_by_category: {},
    })

    expect(error.message).toContain('features_by_category')
  })

  it('rejects a category key that is absent from all_features', () => {
    const error = expectDrift({
      ...currentWire(),
      features_by_category: {
        ...currentWire().features_by_category,
        ghost: { total: 0, enabled: 0, features: [] },
      },
    })

    expect(error.message).toContain('keys must equal the categories')
  })

  it('rejects a category projection that disagrees with all_features', () => {
    const wire = currentWire()
    const error = expectDrift({
      ...wire,
      features_by_category: {
        transport: {
          ...wire.features_by_category.transport,
          features: [
            {
              ...wire.features_by_category.transport.features[0],
              description: 'stale projection',
            },
          ],
        },
      },
    })

    expect(error.message).toContain('same feature values as all_features')
  })
})
