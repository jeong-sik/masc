import { describe, expect, it } from 'vitest'
import { parseKeeperPersistenceProofResponse } from './dashboard-keeper-feature-proof'

function tierStatus(keeperCount: number, observed: number, undetermined: number) {
  if (keeperCount === 0) return 'fail'
  if (observed === keeperCount) return 'pass'
  // Unread Keepers keep the tier off 'fail': nobody can say they missed it.
  if (observed === 0 && undetermined === 0) return 'fail'
  return 'warn'
}

const tier = (
  id: '1h' | '2h' | '4h' | '24h',
  requiredSpanHours: number,
  observedKeepers: string[],
  missingKeepers: string[],
  undeterminedKeepers: string[] = [],
) => ({
  id,
  evidence_kind: 'durable_turn_span',
  required_span_hours: requiredSpanHours,
  status: tierStatus(
    observedKeepers.length + missingKeepers.length + undeterminedKeepers.length,
    observedKeepers.length,
    undeterminedKeepers.length,
  ),
  keeper_count: observedKeepers.length + missingKeepers.length + undeterminedKeepers.length,
  observed_count: observedKeepers.length,
  missing_count: missingKeepers.length,
  undetermined_count: undeterminedKeepers.length,
  observed_keepers: observedKeepers,
  missing_keepers: missingKeepers,
  undetermined_keepers: undeterminedKeepers,
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
      undeterminedCount: 0,
      observedKeepers: ['keeper-a'],
      missingKeepers: ['keeper-b'],
      undeterminedKeepers: [],
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
      'observed, missing and undetermined keepers must not overlap',
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

  it('keeps a Keeper whose history was never reached out of both buckets', () => {
    const unread = {
      generated_at: '2026-08-14T12:00:00Z',
      status: 'warn',
      summary: { feature_count: 5 },
      features: [
        {
          id: 'persistent_24h_turn_exchange',
          status: 'warn',
          summary: '1/2 keepers have durable turn spans >= 24h; 1 more read past the budget',
          duration_tiers: [
            tier('1h', 1, ['keeper-a'], [], ['keeper-b']),
            tier('2h', 2, ['keeper-a'], [], ['keeper-b']),
            tier('4h', 4, ['keeper-a'], [], ['keeper-b']),
            tier('24h', 24, ['keeper-a'], [], ['keeper-b']),
          ],
        },
      ],
      evidence_refs: [],
    }

    const parsed = parseKeeperPersistenceProofResponse(unread)
    const tier24h = parsed.tiers[3]
    expect(tier24h?.undeterminedKeepers).toEqual(['keeper-b'])
    expect(tier24h?.missingKeepers).toEqual([])
    expect(tier24h?.keeperCount).toBe(2)
  })

  it('reads a fleet that is entirely unread as partial, not failed', () => {
    const allUnread = {
      generated_at: '2026-08-14T12:00:00Z',
      status: 'warn',
      summary: { feature_count: 5 },
      features: [
        {
          id: 'persistent_24h_turn_exchange',
          status: 'warn',
          summary: '0/2 keepers have durable turn spans >= 24h; 2 more read past the budget',
          duration_tiers: [
            tier('1h', 1, [], [], ['keeper-a', 'keeper-b']),
            tier('2h', 2, [], [], ['keeper-a', 'keeper-b']),
            tier('4h', 4, [], [], ['keeper-a', 'keeper-b']),
            tier('24h', 24, [], [], ['keeper-a', 'keeper-b']),
          ],
        },
      ],
      evidence_refs: [],
    }

    expect(parseKeeperPersistenceProofResponse(allUnread).status).toBe('warn')
  })

  it('rejects counts that leave Keepers unaccounted for', () => {
    const raw = payload()
    durationTier(raw, 0).keeper_count = 3
    expect(() => parseKeeperPersistenceProofResponse(raw)).toThrow(
      'must equal keeper_count',
    )
  })

  it('rejects an unread set that changes between tiers', () => {
    const drift = payload()
    const tiers = persistenceFeature(drift).duration_tiers
    tiers[3] = tier('24h', 24, ['keeper-a'], [], ['keeper-b'])
    expect(() => parseKeeperPersistenceProofResponse(drift)).toThrow(
      'must report the same unread Keepers as every tier',
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
