import { render } from 'preact'
import { html } from 'htm/preact'
import { describe, it, expect, afterEach } from 'vitest'
import type { Keeper, KeeperMetricPoint } from '../types'
import { InferenceTelemetryPanel } from './keeper-detail-telemetry'

afterEach(() => {
  document.body.innerHTML = ''
})

describe('InferenceTelemetryPanel', () => {
  it('separates wall tok/s from hardware decode tok/s', () => {
    const container = document.createElement('div')
    document.body.appendChild(container)
    const metricsSeries = [
      {
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
        model_used: 'glm-5',
        cost_usd: 0.02,
        handoff_to_model: null,
        handoff_new_generation: null,
        prompt_fingerprint: null,
        prompt_metrics: null,
        ctx_composition: null,
        input_tokens: 120,
        output_tokens: 80,
        total_tokens: 200,
        wall_tokens_per_second: 40,
        inference_telemetry: {
          system_fingerprint: 'fp-a',
          timings: {
            prompt_n: null,
            prompt_ms: null,
            prompt_per_second: 55,
            predicted_n: null,
            predicted_ms: null,
            predicted_per_second: 140,
            cache_n: 10,
          },
          reasoning_tokens: 4,
          peak_memory_gb: null,
          request_latency_ms: 2000,
          ttfrc_ms: null,
          prefill_ms: null,
        },
        fallback_applied: false,
        fallback_hops: 0,
        fallback_from: null,
        fallback_to: null,
        fallback_reason: null,
        timeout_budget: null,
      },
      {
        ts: 2,
        context_ratio: 0.25,
        context_tokens: 250,
        context_max: 1000,
        latency_ms: 1000,
        generation: 1,
        channel: 'turn',
        is_handoff: false,
        is_compaction: false,
        compaction_saved_tokens: 0,
        compaction_trigger: null,
        model_used: 'glm-5',
        cost_usd: 0.03,
        handoff_to_model: null,
        handoff_new_generation: null,
        prompt_fingerprint: null,
        prompt_metrics: null,
        ctx_composition: null,
        input_tokens: 90,
        output_tokens: 60,
        total_tokens: 150,
        wall_tokens_per_second: 60,
        inference_telemetry: {
          system_fingerprint: 'fp-b',
          timings: {
            prompt_n: null,
            prompt_ms: null,
            prompt_per_second: 60,
            predicted_n: null,
            predicted_ms: null,
            predicted_per_second: 150,
            cache_n: 12,
          },
          reasoning_tokens: 8,
          peak_memory_gb: null,
          request_latency_ms: 1000,
          ttfrc_ms: null,
          prefill_ms: null,
        },
        fallback_applied: false,
        fallback_hops: 0,
        fallback_from: null,
        fallback_to: null,
        fallback_reason: null,
        timeout_budget: null,
      },
    ] satisfies KeeperMetricPoint[]
    const keeper = { metrics_series: metricsSeries } as Keeper

    render(html`<${InferenceTelemetryPanel} keeper=${keeper} />`, container)

    expect(container.textContent).toContain('wall tok/s')
    expect(container.textContent).toContain('hw tok/s')
    expect(container.textContent).toContain('avg 50.0')
    expect(container.textContent).toContain('avg 145.0')
  })

  it('does not plot missing API latency as zero', () => {
    const container = document.createElement('div')
    document.body.appendChild(container)
    const metricsSeries = [
      {
        ts: 1,
        context_ratio: 0.2,
        context_tokens: 200,
        context_max: 1000,
        latency_ms: null,
        generation: 1,
        channel: 'turn',
        is_handoff: false,
        is_compaction: false,
        compaction_saved_tokens: 0,
        compaction_trigger: null,
        model_used: 'glm-5',
        cost_usd: 0.02,
        handoff_to_model: null,
        handoff_new_generation: null,
        prompt_fingerprint: null,
        prompt_metrics: null,
        ctx_composition: null,
        input_tokens: 120,
        output_tokens: 80,
        total_tokens: 200,
        wall_tokens_per_second: 40,
        inference_telemetry: {
          system_fingerprint: null,
          timings: null,
          reasoning_tokens: null,
          peak_memory_gb: null,
          request_latency_ms: null,
          ttfrc_ms: null,
          prefill_ms: null,
        },
        fallback_applied: false,
        fallback_hops: 0,
        fallback_from: null,
        fallback_to: null,
        fallback_reason: null,
        timeout_budget: null,
      },
      {
        ts: 2,
        context_ratio: 0.25,
        context_tokens: 250,
        context_max: 1000,
        latency_ms: null,
        generation: 1,
        channel: 'turn',
        is_handoff: false,
        is_compaction: false,
        compaction_saved_tokens: 0,
        compaction_trigger: null,
        model_used: 'glm-5',
        cost_usd: 0.03,
        handoff_to_model: null,
        handoff_new_generation: null,
        prompt_fingerprint: null,
        prompt_metrics: null,
        ctx_composition: null,
        input_tokens: 90,
        output_tokens: 60,
        total_tokens: 150,
        wall_tokens_per_second: 60,
        inference_telemetry: {
          system_fingerprint: null,
          timings: null,
          reasoning_tokens: null,
          peak_memory_gb: null,
          request_latency_ms: null,
          ttfrc_ms: null,
          prefill_ms: null,
        },
        fallback_applied: false,
        fallback_hops: 0,
        fallback_from: null,
        fallback_to: null,
        fallback_reason: null,
        timeout_budget: null,
      },
    ] satisfies KeeperMetricPoint[]
    const keeper = { metrics_series: metricsSeries } as Keeper

    render(html`<${InferenceTelemetryPanel} keeper=${keeper} />`, container)

    expect(container.textContent).toContain('API latency')
    expect(container.textContent).not.toContain('0.0s')
    expect(container.querySelector('svg[aria-label="API 지연 시간 추이"] polyline')).toBeNull()
  })
})
