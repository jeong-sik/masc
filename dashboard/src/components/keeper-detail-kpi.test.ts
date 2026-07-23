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
    generation: 1,
    channel: 'turn',
    is_handoff: false,
    is_compaction: false,
    compaction_saved_tokens: 0,
    compaction_trigger: null,
    model_used: 'runtime',
    cost_usd: 0.01,
    handoff_to_model: null,
    handoff_new_generation: null,
    prompt_fingerprint: null,
    prompt_metrics: null,
    ctx_composition: null,
    input_tokens: 120,
    output_tokens: 80,
    total_tokens: 200,
    wall_tokens_per_second: null,
    inference_telemetry: null,
    fallback_applied: false,
    fallback_hops: 0,
    fallback_from: null,
    fallback_to: null,
    fallback_reason: null,
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
      handoff_count_total: 1,
      compaction_count: 2,
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
  })
})
