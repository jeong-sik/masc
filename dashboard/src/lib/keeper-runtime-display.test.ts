import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { Keeper } from '../types'
import {
  keeperActivityDisplay,
  keeperDisplayModel,
  keeperDisplayStatus,
} from './keeper-runtime-display'

/** Minimal Keeper stub with only the fields relevant to status classification. */
function makeKeeper(overrides: Partial<Keeper> = {}): Keeper {
  return {
    name: 'test-keeper',
    status: 'offline',
    ...overrides,
  } as Keeper
}

describe('keeperDisplayStatus', () => {
  it('returns paused when keeper.paused is true', () => {
    expect(keeperDisplayStatus(makeKeeper({ paused: true }))).toBe('paused')
  })

  it('returns unknown for null keeper', () => {
    expect(keeperDisplayStatus(null)).toBe('unknown')
  })

  it('returns unknown for undefined keeper', () => {
    expect(keeperDisplayStatus(undefined)).toBe('unknown')
  })

  it('passes through non-offline statuses', () => {
    expect(keeperDisplayStatus(makeKeeper({ status: 'active' }))).toBe('active')
    expect(keeperDisplayStatus(makeKeeper({ status: 'idle' }))).toBe('idle')
  })

  describe('offline refinement into unbooted/stopped', () => {
    it('classifies offline keeper with no activity as unbooted', () => {
      const keeper = makeKeeper({
        status: 'offline',
        generation: 0,
        turn_count: 0,
        agent: { exists: false },
      })
      expect(keeperDisplayStatus(keeper)).toBe('unbooted')
    })

    it('classifies inactive keeper with no activity as unbooted', () => {
      const keeper = makeKeeper({
        status: 'inactive',
        generation: 0,
        turn_count: 0,
        agent: { exists: false },
      })
      expect(keeperDisplayStatus(keeper)).toBe('unbooted')
    })

    it('classifies offline keeper with generation > 0 as stopped', () => {
      const keeper = makeKeeper({
        status: 'offline',
        generation: 3,
        turn_count: 0,
      })
      expect(keeperDisplayStatus(keeper)).toBe('stopped')
    })

    it('classifies offline keeper with turn_count > 0 as stopped', () => {
      const keeper = makeKeeper({
        status: 'offline',
        generation: 0,
        turn_count: 5,
      })
      expect(keeperDisplayStatus(keeper)).toBe('stopped')
    })

    it('classifies offline keeper with agent.exists=true but no turns as offline', () => {
      // agent exists but generation=0, turn_count=0 — doesn't match unbooted
      // (agent exists) and doesn't match stopped (no turns/generation)
      const keeper = makeKeeper({
        status: 'offline',
        generation: 0,
        turn_count: 0,
        agent: { exists: true },
      })
      expect(keeperDisplayStatus(keeper)).toBe('offline')
    })

    it('classifies offline keeper with all activity signals as stopped', () => {
      const keeper = makeKeeper({
        status: 'offline',
        generation: 2,
        turn_count: 10,
        agent: { exists: true },
      })
      expect(keeperDisplayStatus(keeper)).toBe('stopped')
    })
  })
})

describe('keeperDisplayModel', () => {
  it('keeps CLI/provider runtime labels intact for active auto profiles', () => {
    expect(
      keeperDisplayModel({
        active_model_label: 'claude_code:auto',
        active_model: 'claude',
        model: 'claude',
      }),
    ).toEqual({ label: '현재 모델', value: 'claude_code:auto' })
  })

  it('keeps active runtime labels ahead of metrics-series fallback', () => {
    expect(
      keeperDisplayModel({
        active_model: 'claude_code:auto',
        metrics_series: [
          { model_used: 'openai:gpt-5.4' },
          { model_used: 'anthropic:claude-sonnet-4-6' },
        ],
      }),
    ).toEqual({ label: '현재 모델', value: 'claude_code:auto' })
  })

  it('uses the latest metrics model when structured runtime model is absent', () => {
    expect(
      keeperDisplayModel({
        metrics_series: [
          { model_used: 'openai:gpt-5.4' },
          { model_used: 'anthropic:claude-sonnet-4-6' },
        ],
      }),
    ).toEqual({ label: '최근 모델', value: 'anthropic:claude-sonnet-4-6' })
  })
})

describe('keeperActivityDisplay', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-04-24T18:00:00Z'))
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('uses heartbeat as the latest live signal when autonomous action is older', () => {
    expect(
      keeperActivityDisplay({
        last_autonomous_action_at: '2026-04-24T12:00:00Z',
        last_heartbeat: '2026-04-24T17:54:00Z',
      }),
    ).toEqual({
      source: 'heartbeat',
      label: '하트비트',
      timestamp: '2026-04-24T17:54:00Z',
      ageSeconds: 360,
    })
  })

  it('does not let agent last_seen override keeper runtime signals', () => {
    expect(
      keeperActivityDisplay(
        { last_heartbeat: '2026-04-24T17:54:00Z' },
        '2026-04-24T17:59:00Z',
      ).source,
    ).toBe('heartbeat')
  })

  it('uses autonomous action when it is newer than heartbeat', () => {
    expect(
      keeperActivityDisplay({
        last_autonomous_action_at: '2026-04-24T17:59:00Z',
        last_heartbeat: '2026-04-24T17:54:00Z',
      }).source,
    ).toBe('autonomous_action')
  })

  it('falls back to numeric activity age when no timestamp exists', () => {
    expect(
      keeperActivityDisplay({
        last_activity_ago_s: 75,
        last_turn_ago_s: 180,
      }),
    ).toEqual({
      source: 'last_activity',
      label: '최근 활동',
      timestamp: null,
      ageSeconds: 75,
    })
  })
})
