import { describe, expect, it } from 'vitest'
import { parseKeeperPersistenceProofResponse } from './dashboard-keeper-feature-proof'

const tier = (
  id: '1h' | '2h' | '4h' | '24h',
  requiredSpanHours: number,
  observedKeepers: string[],
  missingKeepers: string[],
) => ({
  id,
  evidence_kind: 'durable_turn_span',
  required_span_hours: requiredSpanHours,
  status: observedKeepers.length === 0
    ? 'fail'
    : missingKeepers.length === 0 ? 'pass' : 'warn',
  keeper_count: observedKeepers.length + missingKeepers.length,
  observed_count: observedKeepers.length,
  missing_count: missingKeepers.length,
  observed_keepers: observedKeepers,
  missing_keepers: missingKeepers,
})

function payload() {
  return {
    generated_at: '2026-08-14T12:00:00Z',
    status: 'warn',
    summary: { feature_count: 5 },
    features: [
      {
        id: 'persistent_24h_turn_exchange',
        status: 'warn',
        summary: '1/2 keepers have durable turn spans >= 24h',
        duration_tiers: [
          tier('1h', 1, ['keeper-a', 'keeper-b'], []),
          tier('2h', 2, ['keeper-a', 'keeper-b'], []),
          tier('4h', 4, ['keeper-a'], ['keeper-b']),
          tier('24h', 24, ['keeper-a'], ['keeper-b']),
        ],
      },
    ],
    evidence_refs: [],
  }
}

function persistenceFeature(raw: ReturnType<typeof payload>) {
  const [feature] = raw.features
  if (feature == null) throw new Error('persistence fixture is absent')
  return feature
}

function durationTier(raw: ReturnType<typeof payload>, index: number) {
  const value = persistenceFeature(raw).duration_tiers[index]
  if (value == null) throw new Error(`duration tier fixture ${index} is absent`)
  return value
}

describe('parseKeeperPersistenceProofResponse', () => {
  it('projects the exact ordered durable turn-span tiers', () => {
    const parsed = parseKeeperPersistenceProofResponse(payload())

    expect(parsed.generatedAt).toBe('2026-08-14T12:00:00Z')
    expect(parsed.status).toBe('warn')
    expect(parsed.tiers.map(value => value.id)).toEqual(['1h', '2h', '4h', '24h'])
    expect(parsed.tiers[2]).toEqual({
      id: '4h',
      requiredSpanHours: 4,
      status: 'warn',
      evidenceKind: 'durable_turn_span',
      keeperCount: 2,
      observedCount: 1,
      missingCount: 1,
      observedKeepers: ['keeper-a'],
      missingKeepers: ['keeper-b'],
    })
  })

  it('rejects a tier status that disagrees with its evidence counts', () => {
    const raw = payload()
    durationTier(raw, 2).status = 'pass'

    expect(() => parseKeeperPersistenceProofResponse(raw)).toThrow(
      'does not match derived status=warn',
    )
  })

  it('rejects duplicate or overlapping keeper evidence', () => {
    const duplicate = payload()
    durationTier(duplicate, 0).observed_keepers = ['keeper-a', 'keeper-a']
    expect(() => parseKeeperPersistenceProofResponse(duplicate)).toThrow(
      'must not contain duplicate keepers',
    )

    const overlap = payload()
    durationTier(overlap, 2).missing_keepers = ['keeper-a']
    expect(() => parseKeeperPersistenceProofResponse(overlap)).toThrow(
      'observed and missing keepers must not overlap',
    )
  })

  it('rejects reordered tiers and a feature status that disagrees with 24h', () => {
    const reordered = payload()
    const tiers = persistenceFeature(reordered).duration_tiers
    const first = durationTier(reordered, 0)
    tiers[0] = durationTier(reordered, 1)
    tiers[1] = first
    expect(() => parseKeeperPersistenceProofResponse(reordered)).toThrow(
      'duration_tiers[0].id must be 1h',
    )

    const mismatch = payload()
    persistenceFeature(mismatch).status = 'pass'
    expect(() => parseKeeperPersistenceProofResponse(mismatch)).toThrow(
      'must match the 24h tier status',
    )
  })

  it('rejects cross-tier fleet drift and non-monotonic duration evidence', () => {
    const fleetDrift = payload()
    durationTier(fleetDrift, 3).missing_keepers = ['keeper-c']
    expect(() => parseKeeperPersistenceProofResponse(fleetDrift)).toThrow(
      'must describe the same Keeper fleet',
    )

    const nonMonotonic = payload()
    durationTier(nonMonotonic, 2).observed_keepers = ['keeper-b']
    durationTier(nonMonotonic, 2).missing_keepers = ['keeper-a']
    expect(() => parseKeeperPersistenceProofResponse(nonMonotonic)).toThrow(
      'violates duration monotonicity',
    )
  })
})
