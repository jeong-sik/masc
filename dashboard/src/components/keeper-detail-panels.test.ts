import { render } from 'preact'
import { html } from 'htm/preact'
import { describe, it, expect, afterEach } from 'vitest'
import type { Keeper, KeeperMetricPoint, PromptSegmentTelemetry } from '../types'
import {
  autonomyHint,
  formatDuration,
  InferenceTelemetryPanel,
  RelationshipList,
  TraitsList,
} from './keeper-detail-panels'

afterEach(() => {
  document.body.innerHTML = ''
})

describe('autonomyHint', () => {
  it('returns active hint when count is 0 and proactive enabled', () => {
    expect(autonomyHint(0, true)).toBe('활성 · 미발동')
  })

  it('returns disabled hint when count is 0 and proactive disabled', () => {
    expect(autonomyHint(0, false)).toBe('자율 비활성')
  })

  it('returns disabled hint when count is 0 and proactive undefined', () => {
    expect(autonomyHint(0, undefined)).toBe('자율 비활성')
  })

  it('returns undefined when count is positive', () => {
    expect(autonomyHint(5, true)).toBeUndefined()
    expect(autonomyHint(1, false)).toBeUndefined()
  })

  it('returns disabled hint when count is undefined', () => {
    expect(autonomyHint(undefined, undefined)).toBe('자율 비활성')
  })
})

// ── formatDuration ────────────────────────────────────────────

describe('formatDuration', () => {
  it('formats seconds under 60', () => {
    expect(formatDuration(0)).toBe('0초')
    expect(formatDuration(30)).toBe('30초')
    expect(formatDuration(59)).toBe('59초')
  })

  it('formats minutes under 3600', () => {
    expect(formatDuration(60)).toBe('1분')
    expect(formatDuration(120)).toBe('2분')
    expect(formatDuration(3599)).toBe('59분')
  })

  it('formats hours with remaining minutes', () => {
    expect(formatDuration(3600)).toBe('1시간 0분')
    expect(formatDuration(3660)).toBe('1시간 1분')
    expect(formatDuration(7384)).toBe('2시간 3분')
  })
})

// ── formatFingerprint ─────────────────────────────────────────

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
})

describe('RelationshipList and TraitsList primitives', () => {
  it('renders relationship names with the shared status chip primitive', () => {
    const container = document.createElement('div')
    document.body.appendChild(container)

    render(html`<${RelationshipList} rels=${{ alpha: 'mentor' }} />`, container)

    const chip = container.querySelector('[data-status-chip]')
    expect(chip?.textContent).toContain('alpha')
    expect(chip?.getAttribute('data-status-chip-tone')).toBe('info')
    expect(chip?.getAttribute('data-status-chip-uppercase')).toBe('false')
  })

  it('renders trait labels with the shared status chip primitive', () => {
    const container = document.createElement('div')
    document.body.appendChild(container)

    render(html`<${TraitsList} label="traits" traits=${['planner']} />`, container)

    const chip = container.querySelector('[data-status-chip]')
    expect(chip?.textContent).toContain('planner')
    expect(chip?.getAttribute('data-status-chip-tone')).toBe('info')
    expect(chip?.getAttribute('data-status-chip-uppercase')).toBe('false')
  })
})
