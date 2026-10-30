import { h } from 'preact'
import { cleanup, render, screen } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import '@testing-library/jest-dom'
import type { Keeper, KeeperMetricPoint } from '../types'
import { KpiGrid } from './keeper-detail-kpi'

afterEach(() => {
  cleanup()
})

function metricPoint(overrides: Partial<KeeperMetricPoint>): KeeperMetricPoint {
  return {
    ts: 1,
    context_ratio: 0.2,
    context_tokens: 200,
    context_max: 1000,
    latency_ms: 2000,
    channel: 'turn',
    cost_usd: 0.01,
    prompt_fingerprint: null,
    prompt_metrics: null,
    ctx_composition: null,
    input_tokens: 120,
    output_tokens: 80,
    total_tokens: 200,
    wall_tokens_per_second: null,
    inference_telemetry: null,
    ...overrides,
  }
}

describe('KpiGrid', () => {
  it('surfaces latest keeper tok/sec in the detail KPI grid', () => {
    const keeper = {
      name: 'sangsu',
      status: 'active',
      context_ratio: 0.2,
      context_tokens: 200,
      generation: 3,
      turn_count: 9,
      metrics_series: [
        metricPoint({
          wall_tokens_per_second: 40,
          inference_telemetry: {
            system_fingerprint: null,
            timings: {
              prompt_n: null,
              prompt_ms: null,
              prompt_per_second: null,
              predicted_n: null,
              predicted_ms: null,
              predicted_per_second: 140,
              cache_n: null,
            },
            reasoning_tokens: null,
            peak_memory_gb: null,
            request_latency_ms: null,
            ttfrc_ms: null,
            prefill_ms: null,
          },
        }),
        metricPoint({
          ts: 2,
          wall_tokens_per_second: 60,
          inference_telemetry: {
            system_fingerprint: null,
            timings: {
              prompt_n: null,
              prompt_ms: null,
              prompt_per_second: null,
              predicted_n: null,
              predicted_ms: null,
              predicted_per_second: 150,
              cache_n: null,
            },
            reasoning_tokens: null,
            peak_memory_gb: null,
            request_latency_ms: null,
            ttfrc_ms: null,
            prefill_ms: null,
          },
        }),
      ],
    } as Keeper

    render(h(KpiGrid, { keeper }))

    expect(screen.getByText('wall tok/s')).toBeInTheDocument()
    expect(screen.getByText('60.0 tok/s')).toBeInTheDocument()
    expect(screen.getByText('hw tok/s')).toBeInTheDocument()
    expect(screen.getByText('150.0 tok/s')).toBeInTheDocument()
    expect(screen.queryByText('인계')).not.toBeInTheDocument()
  })
})

// Wire normalization and the real lifetime KPI share the same coverage facts.
describe('lifetime pricing coverage', () => {
  it('shows numeric zero as unknown history and explicit priced zero as free', async () => {
    const { normalizeKeepers } = await import('../keeper-store-normalize')
    const [unknown] = normalizeKeepers([{ name: 'cost-fixture', status: 'ready', total_cost_usd: 0 }])
    render(h(KpiGrid, { keeper: unknown! }))
    expect(screen.getByText(/history unobserved/)).toBeInTheDocument()
    cleanup()
    const [priced] = normalizeKeepers([{ name: 'cost-fixture', status: 'ready', total_cost_usd: {
      known_cost_usd: 0, priced_readings: 1, unpriced_readings: 0,
      unresolved_readings: 0, unobserved_attempts: 0, history: 'complete',
    } }])
    render(h(KpiGrid, { keeper: priced! }))
    expect(screen.getByText('$0.0000')).toBeInTheDocument()
    expect(screen.queryByText(/history unobserved/)).toBeNull()
  })

  it('shows the known part and preserves unpriced and unresolved evidence', async () => {
    const { normalizeKeepers } = await import('../keeper-store-normalize')
    const [mixed] = normalizeKeepers([{ name: 'cost-fixture', status: 'ready', total_cost_usd: {
      known_cost_usd: 2, priced_readings: 1, unpriced_readings: 2,
      unresolved_readings: 3, unobserved_attempts: 1, history: 'complete',
    } }])
    render(h(KpiGrid, { keeper: mixed! }))
    expect(screen.getByText('$2.0000 known · 1 priced / 2 unpriced / 3 unresolved readings · 1 unobserved attempts')).toBeInTheDocument()
  })
})
