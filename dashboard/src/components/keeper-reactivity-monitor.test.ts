import { describe, it, expect } from 'vitest'
import {
  extractKeeperStopSummaries,
  extractProactiveSkips,
  extractBatchTerminations,
  isKeeperPaused,
} from './keeper-reactivity-monitor'
import type { ParsedMetric } from './prometheus-metrics'
import type { Keeper } from '../types'

// ── Helpers ──────────────────────────────────────────────────────────────

function makeMetric(
  name: string,
  samples: Array<{ labels: Record<string, string>; value: number }>,
): ParsedMetric {
  return {
    name,
    help: '',
    type: 'counter',
    samples: samples.map(s => ({ name, labels: s.labels, value: s.value })),
  }
}

// ── extractKeeperStopSummaries ────────────────────────────────────────────

describe('extractKeeperStopSummaries', () => {
  it('returns empty array for empty input', () => {
    expect(extractKeeperStopSummaries([])).toEqual([])
  })

  it('aggregates stale_termination_total per keeper', () => {
    const metrics: ParsedMetric[] = [
      makeMetric('masc_keeper_stale_termination_total', [
        { labels: { keeper: 'alpha' }, value: 5 },
        { labels: { keeper: 'beta' }, value: 3 },
      ]),
    ]
    const summaries = extractKeeperStopSummaries(metrics)
    const alpha = summaries.find(s => s.keeper === 'alpha')!
    const beta = summaries.find(s => s.keeper === 'beta')!
    expect(alpha.stale_total).toBe(5)
    expect(beta.stale_total).toBe(3)
  })

  it('aggregates stale_termination_by_class_total per class', () => {
    const metrics: ParsedMetric[] = [
      makeMetric('masc_keeper_stale_termination_by_class_total', [
        { labels: { keeper: 'alpha', class: 'idle_turn' }, value: 2 },
        { labels: { keeper: 'alpha', class: 'in_turn_hung' }, value: 1 },
        { labels: { keeper: 'alpha', class: 'noop_failure_loop' }, value: 3 },
      ]),
    ]
    const summaries = extractKeeperStopSummaries(metrics)
    const alpha = summaries.find(s => s.keeper === 'alpha')!
    expect(alpha.idle_turn).toBe(2)
    expect(alpha.in_turn_hung).toBe(1)
    expect(alpha.noop_failure_loop).toBe(3)
  })

  it('aggregates storm_pauses from masc_keeper_stale_storm_paused_total', () => {
    const metrics: ParsedMetric[] = [
      makeMetric('masc_keeper_stale_storm_paused_total', [
        { labels: { keeper: 'gamma' }, value: 7 },
      ]),
    ]
    const summaries = extractKeeperStopSummaries(metrics)
    const gamma = summaries.find(s => s.keeper === 'gamma')!
    expect(gamma.storm_pauses).toBe(7)
  })

  it('aggregates budget_loop_pauses from masc_keeper_oas_timeout_budget_loop_paused_total', () => {
    const metrics: ParsedMetric[] = [
      makeMetric('masc_keeper_oas_timeout_budget_loop_paused_total', [
        { labels: { keeper: 'delta' }, value: 4 },
      ]),
    ]
    const summaries = extractKeeperStopSummaries(metrics)
    const delta = summaries.find(s => s.keeper === 'delta')!
    expect(delta.budget_loop_pauses).toBe(4)
  })

  it('aggregates budget_strikes from masc_keeper_oas_timeout_budget_strike', () => {
    const metrics: ParsedMetric[] = [
      makeMetric('masc_keeper_oas_timeout_budget_strike', [
        { labels: { keeper: 'epsilon' }, value: 2 },
      ]),
    ]
    const summaries = extractKeeperStopSummaries(metrics)
    const epsilon = summaries.find(s => s.keeper === 'epsilon')!
    expect(epsilon.budget_strikes).toBe(2)
  })

  it('aggregates budget_strikes from masc_keeper_oas_timeout_budget_strike_total', () => {
    const metrics: ParsedMetric[] = [
      makeMetric('masc_keeper_oas_timeout_budget_strike_total', [
        { labels: { keeper: 'zeta' }, value: 6 },
      ]),
    ]
    const summaries = extractKeeperStopSummaries(metrics)
    const zeta = summaries.find(s => s.keeper === 'zeta')!
    expect(zeta.budget_strikes).toBe(6)
  })

  it('skips samples without keeper label', () => {
    const metrics: ParsedMetric[] = [
      makeMetric('masc_keeper_stale_termination_total', [
        { labels: {}, value: 99 },
      ]),
    ]
    expect(extractKeeperStopSummaries(metrics)).toEqual([])
  })

  it('merges data from multiple metric families for the same keeper', () => {
    const metrics: ParsedMetric[] = [
      makeMetric('masc_keeper_stale_termination_total', [
        { labels: { keeper: 'alpha' }, value: 5 },
      ]),
      makeMetric('masc_keeper_stale_storm_paused_total', [
        { labels: { keeper: 'alpha' }, value: 3 },
      ]),
    ]
    const summaries = extractKeeperStopSummaries(metrics)
    expect(summaries).toHaveLength(1)
    const alpha = summaries[0]!
    expect(alpha.stale_total).toBe(5)
    expect(alpha.storm_pauses).toBe(3)
  })

  it('sorts by stale_total descending then alphabetically', () => {
    const metrics: ParsedMetric[] = [
      makeMetric('masc_keeper_stale_termination_total', [
        { labels: { keeper: 'beta' }, value: 2 },
        { labels: { keeper: 'alpha' }, value: 5 },
        { labels: { keeper: 'gamma' }, value: 2 },
      ]),
    ]
    const summaries = extractKeeperStopSummaries(metrics)
    expect(summaries.map(s => s.keeper)).toEqual(['alpha', 'beta', 'gamma'])
  })

  it('initializes all numeric fields to 0 for missing metrics', () => {
    const metrics: ParsedMetric[] = [
      makeMetric('masc_keeper_stale_termination_total', [
        { labels: { keeper: 'solo' }, value: 1 },
      ]),
    ]
    const summaries = extractKeeperStopSummaries(metrics)
    const solo = summaries[0]!
    expect(solo.idle_turn).toBe(0)
    expect(solo.in_turn_hung).toBe(0)
    expect(solo.noop_failure_loop).toBe(0)
    expect(solo.budget_strikes).toBe(0)
    expect(solo.storm_pauses).toBe(0)
    expect(solo.budget_loop_pauses).toBe(0)
  })
})

// ── extractProactiveSkips ─────────────────────────────────────────────────

describe('extractProactiveSkips', () => {
  it('returns empty array for empty input', () => {
    expect(extractProactiveSkips([])).toEqual([])
  })

  it('extracts rows from masc_keeper_proactive_skip_total', () => {
    const metrics: ParsedMetric[] = [
      makeMetric('masc_keeper_proactive_skip_total', [
        { labels: { keeper: 'alpha', reason: 'no_signal' }, value: 10 },
        { labels: { keeper: 'alpha', reason: 'cooldown_pending' }, value: 3 },
        { labels: { keeper: 'beta', reason: 'keeper_paused' }, value: 7 },
      ]),
    ]
    const rows = extractProactiveSkips(metrics)
    expect(rows).toHaveLength(3)
    expect(rows.find(r => r.keeper === 'alpha' && r.reason === 'no_signal')?.count).toBe(10)
    expect(rows.find(r => r.keeper === 'beta' && r.reason === 'keeper_paused')?.count).toBe(7)
  })

  it('skips samples with missing keeper or reason labels', () => {
    const metrics: ParsedMetric[] = [
      makeMetric('masc_keeper_proactive_skip_total', [
        { labels: { keeper: 'alpha' }, value: 5 },
        { labels: { reason: 'no_signal' }, value: 3 },
        { labels: {}, value: 1 },
      ]),
    ]
    expect(extractProactiveSkips(metrics)).toEqual([])
  })

  it('sorts by count descending', () => {
    const metrics: ParsedMetric[] = [
      makeMetric('masc_keeper_proactive_skip_total', [
        { labels: { keeper: 'alpha', reason: 'cooldown_pending' }, value: 2 },
        { labels: { keeper: 'alpha', reason: 'no_signal' }, value: 10 },
        { labels: { keeper: 'beta', reason: 'no_signal' }, value: 5 },
      ]),
    ]
    const rows = extractProactiveSkips(metrics)
    expect(rows[0]!.count).toBe(10)
    expect(rows[1]!.count).toBe(5)
    expect(rows[2]!.count).toBe(2)
  })

  it('ignores non-proactive-skip metrics', () => {
    const metrics: ParsedMetric[] = [
      makeMetric('masc_keeper_stale_termination_total', [
        { labels: { keeper: 'alpha' }, value: 5 },
      ]),
    ]
    expect(extractProactiveSkips(metrics)).toEqual([])
  })
})

// ── extractBatchTerminations ──────────────────────────────────────────────

describe('extractBatchTerminations', () => {
  it('returns empty array for empty input', () => {
    expect(extractBatchTerminations([])).toEqual([])
  })

  it('returns empty array when metric is absent', () => {
    const metrics: ParsedMetric[] = [
      makeMetric('masc_keeper_stale_termination_total', [
        { labels: { keeper: 'alpha' }, value: 5 },
      ]),
    ]
    expect(extractBatchTerminations(metrics)).toEqual([])
  })

  it('returns a single fleet-wide row for unlabeled counter', () => {
    // masc_keeper_stale_termination_batch_total has no labels on the backend.
    const metrics: ParsedMetric[] = [
      makeMetric('masc_keeper_stale_termination_batch_total', [
        { labels: {}, value: 7 },
      ]),
    ]
    const rows = extractBatchTerminations(metrics)
    expect(rows).toHaveLength(1)
    expect(rows[0]!.batch).toBe('fleet')
    expect(rows[0]!.count).toBe(7)
  })

  it('sums multiple samples into one fleet-wide row', () => {
    // If the backend ever emits multiple samples they are aggregated.
    const metrics: ParsedMetric[] = [
      makeMetric('masc_keeper_stale_termination_batch_total', [
        { labels: {}, value: 3 },
        { labels: {}, value: 5 },
      ]),
    ]
    const rows = extractBatchTerminations(metrics)
    expect(rows).toHaveLength(1)
    expect(rows[0]!.count).toBe(8)
  })

  it('returns empty when total is 0', () => {
    const metrics: ParsedMetric[] = [
      makeMetric('masc_keeper_stale_termination_batch_total', [
        { labels: {}, value: 0 },
      ]),
    ]
    expect(extractBatchTerminations(metrics)).toEqual([])
  })
})

// ── isKeeperPaused ────────────────────────────────────────────────────────

describe('isKeeperPaused', () => {
  function keeper(overrides: Partial<Keeper>): Keeper {
    return { name: 'test', status: 'active', ...overrides } satisfies Keeper
  }

  it('returns true when paused flag is set', () => {
    expect(isKeeperPaused(keeper({ paused: true }))).toBe(true)
  })

  it('returns true when phase is Paused', () => {
    expect(isKeeperPaused(keeper({ phase: 'Paused' }))).toBe(true)
  })

  it('returns true when pipeline_stage is paused', () => {
    expect(isKeeperPaused(keeper({ pipeline_stage: 'paused' }))).toBe(true)
  })

  it('returns false for a running keeper', () => {
    expect(isKeeperPaused(keeper({ phase: 'Running', paused: false }))).toBe(false)
  })

  it('returns false when paused is false and phase is Running', () => {
    expect(isKeeperPaused(keeper({ paused: false, phase: 'Running', pipeline_stage: 'thinking' }))).toBe(false)
  })

  it('returns false when paused is undefined (unset)', () => {
    expect(isKeeperPaused(keeper({ phase: 'Running' }))).toBe(false)
  })
})
