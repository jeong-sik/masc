import { describe, expect, it } from 'vitest'

import {
  featureMatchesSearch,
  featureMatchesStatus,
  filterFeatures,
  statusLabel,
  statusChipClass,
} from './feature-health'

type FeatureStatus = 'healthy' | 'warning' | 'inactive' | 'deprecated'

// Minimal shape accepted by the pure helpers. Mirrors the FeatureHealthItem
// fields actually read by the filter functions — avoids depending on the
// component's internal type surface.
interface TestFeature {
  env_name: string
  description: string
  status: FeatureStatus
}

const sample: TestFeature[] = [
  {
    env_name: 'MASC_ENABLE_KEEPER_AUTOBOOT',
    description: '서버 시작 시 키퍼 자동 기동',
    status: 'healthy',
  },
  {
    env_name: 'MASC_ALLOW_REPO_CONFIG_FALLBACK',
    description: 'repo 내 설정 파일 fallback 허용',
    status: 'warning',
  },
  {
    env_name: 'MASC_LEGACY_CASCADE_ROUTING',
    description: 'legacy cascade 라우팅 (deprecated)',
    status: 'deprecated',
  },
  {
    env_name: 'MASC_EXPERIMENTAL_LIVE_JUDGE',
    description: '실시간 judge 실험 기능',
    status: 'inactive',
  },
]

describe('featureMatchesSearch', () => {
  const item = sample[0]!

  it('returns true for empty or whitespace-only query', () => {
    expect(featureMatchesSearch(item, '')).toBe(true)
    expect(featureMatchesSearch(item, '   ')).toBe(true)
  })

  it('matches substring in env_name', () => {
    expect(featureMatchesSearch(item, 'KEEPER')).toBe(true)
    expect(featureMatchesSearch(item, 'AUTOBOOT')).toBe(true)
  })

  it('matches substring in description', () => {
    expect(featureMatchesSearch(item, '자동 기동')).toBe(true)
    expect(featureMatchesSearch(item, '키퍼')).toBe(true)
  })

  it('is case-insensitive for ASCII queries', () => {
    expect(featureMatchesSearch(item, 'keeper')).toBe(true)
    expect(featureMatchesSearch(item, 'Keeper')).toBe(true)
    expect(featureMatchesSearch(item, 'autoboot')).toBe(true)
  })

  it('ignores surrounding whitespace in the query', () => {
    expect(featureMatchesSearch(item, '  keeper  ')).toBe(true)
  })

  it('returns false when the query matches neither field', () => {
    expect(featureMatchesSearch(item, 'nonexistent_flag')).toBe(false)
    expect(featureMatchesSearch(item, 'xyz123')).toBe(false)
  })
})

describe('featureMatchesStatus', () => {
  const healthy: Pick<TestFeature, 'status'> = { status: 'healthy' }
  const deprecated: Pick<TestFeature, 'status'> = { status: 'deprecated' }

  it('returns true for status "all" regardless of item status', () => {
    expect(featureMatchesStatus(healthy, 'all')).toBe(true)
    expect(featureMatchesStatus(deprecated, 'all')).toBe(true)
  })

  it('returns true only when status matches exactly', () => {
    expect(featureMatchesStatus(healthy, 'healthy')).toBe(true)
    expect(featureMatchesStatus(healthy, 'deprecated')).toBe(false)
    expect(featureMatchesStatus(deprecated, 'deprecated')).toBe(true)
    expect(featureMatchesStatus(deprecated, 'warning')).toBe(false)
  })
})

describe('filterFeatures', () => {
  it('returns the input reference when no filter is active (fast path)', () => {
    expect(filterFeatures(sample, '', 'all')).toBe(sample)
    expect(filterFeatures(sample, '   ', 'all')).toBe(sample)
  })

  it('filters by status only', () => {
    const result = filterFeatures(sample, '', 'healthy')
    expect(result.map((f) => f.env_name)).toEqual(['MASC_ENABLE_KEEPER_AUTOBOOT'])
  })

  it('filters by search query only', () => {
    const result = filterFeatures(sample, 'cascade', 'all')
    expect(result.map((f) => f.env_name)).toEqual(['MASC_LEGACY_CASCADE_ROUTING'])
  })

  it('combines search and status filters with AND semantics', () => {
    // Only warnings whose description or name contains "fallback".
    const result = filterFeatures(sample, 'fallback', 'warning')
    expect(result.map((f) => f.env_name)).toEqual(['MASC_ALLOW_REPO_CONFIG_FALLBACK'])
  })

  it('returns an empty array when combined filters match nothing', () => {
    // "deprecated" items exist, but none of them mention "autoboot".
    expect(filterFeatures(sample, 'autoboot', 'deprecated')).toEqual([])
  })

  it('does not mutate the source array', () => {
    const snapshot = sample.map((f) => f.env_name)
    filterFeatures(sample, 'keeper', 'healthy')
    expect(sample.map((f) => f.env_name)).toEqual(snapshot)
  })

  it('preserves extra fields on the input objects', () => {
    const rich = [
      {
        env_name: 'FLAG_A',
        description: 'alpha',
        status: 'healthy' as FeatureStatus,
        extra: 42,
      },
      {
        env_name: 'FLAG_B',
        description: 'beta',
        status: 'deprecated' as FeatureStatus,
        extra: 7,
      },
    ]
    const result = filterFeatures(rich, 'alpha', 'all')
    expect(result).toHaveLength(1)
    expect(result[0]).toEqual({
      env_name: 'FLAG_A',
      description: 'alpha',
      status: 'healthy',
      extra: 42,
    })
  })

  it('is case-insensitive when filtering by search query', () => {
    const result = filterFeatures(sample, 'KEEPER', 'all')
    expect(result.map((f) => f.env_name)).toEqual(['MASC_ENABLE_KEEPER_AUTOBOOT'])
  })
})

describe('statusLabel', () => {
  it.each([
    ['healthy', '정상'],
    ['warning', '실험적'],
    ['inactive', '비활성'],
    ['deprecated', '폐기 예정'],
  ] as const)('statusLabel(%s) → %s', (status, expected) => {
    expect(statusLabel(status)).toBe(expected)
  })
})

describe('statusChipClass', () => {
  it.each([
    ['healthy', 'border-[var(--ok-30)] bg-[var(--ok-12)] text-[var(--color-status-ok)]'],
    ['warning', 'border-[var(--warn-30)] bg-[var(--warn-12)] text-[var(--color-status-warn)]'],
    ['inactive', 'border-[var(--white-12)] bg-[var(--white-4)] text-[var(--color-fg-muted)]'],
    ['deprecated', 'border-[var(--bad-30)] bg-[var(--bad-12)] text-[var(--color-status-err)]'],
  ] as const)('statusChipClass(%s) → %s', (status, expected) => {
    expect(statusChipClass(status)).toBe(expected)
  })
})
