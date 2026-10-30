import { describe, expect, it } from 'vitest'
import type { KeeperCostMetric, KeeperMetricsRead } from '../../api/dashboard'
import { keeperCostReadCoverage } from './keeper-cost-read-coverage'

function keeper(name: string, metrics_read: KeeperMetricsRead): KeeperCostMetric {
  return {
    keeper_name: name,
    metrics_read,
    total_cost_usd: null,
    cost_reported_samples: 0,
    cost_unreported_samples: 0,
    cost_unread_samples: 0,
    total_input_tokens: null,
    total_output_tokens: null,
    total_tokens: null,
    tokens_reported_samples: 0,
    tokens_unreported_samples: 0,
    tokens_unread_samples: 0,
    p50_latency_ms: null,
    p95_latency_ms: null,
    sample_count: 0,
  }
}

describe('keeperCostReadCoverage', () => {
  it('names the keepers whose store could not be read and those read with bad lines', () => {
    const coverage = keeperCostReadCoverage([
      keeper('whole', { state: 'read', malformed_rows: 0, unread_turn_rows: 0 }),
      keeper('unreadable', { state: 'failed', reason: 'disk read failed' }),
      keeper('torn', { state: 'read', malformed_rows: 2, unread_turn_rows: 0 }),
      keeper('turns-lost', { state: 'read', malformed_rows: 0, unread_turn_rows: 1 }),
    ])
    expect(coverage).toEqual({ unreadKeepers: ['unreadable'], partialKeepers: ['torn', 'turns-lost'] })
  })

  it('reports nothing when every store was read in full', () => {
    expect(keeperCostReadCoverage([keeper('whole', { state: 'read', malformed_rows: 0, unread_turn_rows: 0 })]))
      .toEqual({ unreadKeepers: [], partialKeepers: [] })
    expect(keeperCostReadCoverage([])).toEqual({ unreadKeepers: [], partialKeepers: [] })
  })
})
