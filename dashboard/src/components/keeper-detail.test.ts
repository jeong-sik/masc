import { beforeEach, describe, expect, it, vi } from 'vitest'

import type { Keeper } from '../types'

const mocks = vi.hoisted(() => ({
  loadKeeperConfig: vi.fn(async () => {}),
  resetKeeperConfig: vi.fn(),
  selectKeeper: vi.fn(),
}))

vi.mock('./keeper-config-panel', async () => {
  const actual = await vi.importActual<typeof import('./keeper-config-panel')>('./keeper-config-panel')
  return {
    ...actual,
    KeeperConfigPanel: () => null,
    loadKeeperConfig: mocks.loadKeeperConfig,
    resetKeeperConfig: mocks.resetKeeperConfig,
  }
})

vi.mock('../keeper-runtime', () => ({
  selectKeeper: mocks.selectKeeper,
}))

import {
  closeKeeperDetail,
  filterCheckpointHistory,
  lineageTransitionLabel,
  lineageVerdictMeta,
  openKeeperDetail,
  selectedKeeper,
} from './keeper-detail'
import type { KeeperCheckpointSummary } from '../api/keeper'

describe('openKeeperDetail', () => {
  beforeEach(() => {
    selectedKeeper.value = null
    mocks.loadKeeperConfig.mockClear()
    mocks.resetKeeperConfig.mockClear()
    mocks.selectKeeper.mockClear()
  })

  it('selects the keeper and preloads config on modal open', () => {
    const keeper: Keeper = {
      name: 'sangsu',
      status: 'active',
    }

    openKeeperDetail(keeper)

    expect(selectedKeeper.value).toEqual(keeper)
    expect(mocks.selectKeeper).toHaveBeenCalledWith('sangsu')
    expect(mocks.loadKeeperConfig).toHaveBeenCalledWith('sangsu')
  })

  it('resets modal-local state on close', () => {
    const keeper: Keeper = {
      name: 'sangsu',
      status: 'active',
    }

    openKeeperDetail(keeper)
    closeKeeperDetail()

    expect(selectedKeeper.value).toBeNull()
    expect(mocks.resetKeeperConfig).toHaveBeenCalledTimes(1)
  })
})

function makeSummary(overrides: Partial<KeeperCheckpointSummary> = {}): KeeperCheckpointSummary {
  return {
    snapshot_id: 'snap-000',
    source_kind: 'oas_history',
    is_current: false,
    path: '/tmp/snap-000.json',
    created_at: 1_700_000_000,
    generation: 1,
    message_count: 10,
    system_prompt_present: true,
    latest_preview: null,
    continuity_summary: null,
    file_stat: null,
    ...overrides,
  }
}

describe('filterCheckpointHistory', () => {
  const rows: readonly KeeperCheckpointSummary[] = [
    makeSummary({
      snapshot_id: 'snap-abc123',
      source_kind: 'oas_history',
      latest_preview: '유저 질문에 답변 완료',
      continuity_summary: 'Keeper heartbeat stable',
    }),
    makeSummary({
      snapshot_id: 'snap-def456',
      source_kind: 'oas_current',
      latest_preview: 'Compaction triggered',
      continuity_summary: null,
    }),
    makeSummary({
      snapshot_id: 'snap-ghi789',
      source_kind: 'oas_history',
      latest_preview: null,
      continuity_summary: null,
    }),
  ]

  it('returns the input reference for empty query (no allocation)', () => {
    expect(filterCheckpointHistory(rows, '')).toBe(rows)
  })

  it('returns the input reference for whitespace-only query', () => {
    expect(filterCheckpointHistory(rows, '   \t\n ')).toBe(rows)
  })

  it('matches by snapshot_id substring (case-insensitive)', () => {
    const result = filterCheckpointHistory(rows, 'ABC')
    expect(result).toHaveLength(1)
    expect(result[0]?.snapshot_id).toBe('snap-abc123')
  })

  it('matches by source_kind', () => {
    const result = filterCheckpointHistory(rows, 'oas_current')
    expect(result).toHaveLength(1)
    expect(result[0]?.snapshot_id).toBe('snap-def456')
  })

  it('matches by latest_preview text including Korean', () => {
    const result = filterCheckpointHistory(rows, '답변')
    expect(result).toHaveLength(1)
    expect(result[0]?.snapshot_id).toBe('snap-abc123')
  })

  it('matches by continuity_summary', () => {
    const result = filterCheckpointHistory(rows, 'heartbeat')
    expect(result).toHaveLength(1)
    expect(result[0]?.snapshot_id).toBe('snap-abc123')
  })

  it('trims the query before matching', () => {
    const result = filterCheckpointHistory(rows, '  compaction  ')
    expect(result).toHaveLength(1)
    expect(result[0]?.snapshot_id).toBe('snap-def456')
  })

  it('returns empty array when nothing matches', () => {
    expect(filterCheckpointHistory(rows, 'no-such-token')).toEqual([])
  })

  it('does not mutate the input array or its elements', () => {
    const snapshot = rows.map(r => ({ ...r }))
    filterCheckpointHistory(rows, 'abc')
    expect(rows.map(r => ({ ...r }))).toEqual(snapshot)
  })

  it('handles rows with null preview and null continuity_summary without throwing', () => {
    const onlyNulls: readonly KeeperCheckpointSummary[] = [
      makeSummary({ snapshot_id: 'snap-null', latest_preview: null, continuity_summary: null }),
    ]
    expect(() => filterCheckpointHistory(onlyNulls, 'missing')).not.toThrow()
    expect(filterCheckpointHistory(onlyNulls, 'missing')).toEqual([])
    expect(filterCheckpointHistory(onlyNulls, 'null')).toHaveLength(1)
  })

  it('preserves the original order of matching rows', () => {
    const result = filterCheckpointHistory(rows, 'snap-')
    expect(result.map(r => r.snapshot_id)).toEqual(['snap-abc123', 'snap-def456', 'snap-ghi789'])
  })
})

describe('lineageVerdictMeta', () => {
  it('maps verified to an operator-facing preserved-state explanation', () => {
    expect(lineageVerdictMeta('verified')).toEqual({
      badgeLabel: 'state preserved',
      detail: 'Continuity checks whether the keeper goal, instructions, and saved state summary carried across the handoff.',
    })
  })

  it('maps drift_detected to a review-oriented explanation', () => {
    expect(lineageVerdictMeta('drift_detected')).toEqual({
      badgeLabel: 'review drift',
      detail: 'The handoff completed, but the saved continuity summary changed enough that an operator should review it.',
    })
  })

  it('falls back to unknown for unmapped verdicts', () => {
    expect(lineageVerdictMeta('mystery')).toEqual({
      badgeLabel: 'unknown',
      detail: 'A continuity signal exists, but this verdict is not yet mapped to an operator-facing explanation.',
    })
  })
})

describe('lineageTransitionLabel', () => {
  it('uses root when the parent generation is absent', () => {
    expect(lineageTransitionLabel(null, 3)).toBe('root -> gen 3')
  })

  it('renders explicit generation-to-generation transitions', () => {
    expect(lineageTransitionLabel(4, 5)).toBe('gen 4 -> gen 5')
  })
})
