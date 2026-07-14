import { render } from 'preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it } from 'vitest'
import type { Keeper, KeeperMetricPoint } from '../types'
import { CtxCompositionPanel } from './keeper-detail-ctx-composition'
import { PromptTelemetryPanel } from './keeper-detail-telemetry'

afterEach(() => {
  document.body.innerHTML = ''
})

function metricPoint(overrides: Partial<KeeperMetricPoint>): KeeperMetricPoint {
  return {
    ts: 1,
    context_ratio: 0,
    context_tokens: 0,
    context_max: 0,
    latency_ms: null,
    generation: 1,
    channel: 'turn',
    is_handoff: false,
    is_compaction: false,
    compaction_saved_tokens: 0,
    compaction_trigger: null,
    model_used: 'test-model',
    cost_usd: 0,
    handoff_to_model: null,
    handoff_new_generation: null,
    prompt_fingerprint: null,
    prompt_metrics: null,
    ctx_composition: null,
    input_tokens: null,
    output_tokens: null,
    total_tokens: null,
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

describe('keeper prompt byte telemetry', () => {
  it('renders prompt measurements as bytes without token estimates', () => {
    const container = document.createElement('div')
    const keeper = {
      name: 'prompt-keeper',
      status: 'active',
      metrics_series: [metricPoint({
        prompt_fingerprint: 'prompt-fp',
        prompt_metrics: {
          fingerprint: 'prompt-fp',
          total_bytes: 830,
          cacheable_bytes: 512,
          segments: {
            system_prompt: { bytes: 512, fingerprint: 'system-fp' },
          },
        },
      })],
    } as Keeper

    render(html`<${PromptTelemetryPanel} keeper=${keeper} />`, container)

    expect(container.textContent).toContain('prompt bytes')
    expect(container.textContent).toContain('latest 830 bytes')
    expect(container.textContent).toContain('cacheable 512 bytes')
    expect(container.textContent).not.toContain('estimated prompt tokens')
  })

  it('keeps provider tokens separate from attributed bytes', () => {
    const container = document.createElement('div')
    const keeper = {
      name: 'composition-keeper',
      status: 'active',
      metrics_series: [metricPoint({
        ctx_composition: {
          actual_input_tokens: 1000,
          attributed_bytes: 1160,
          segments: {
            system_prompt: { bytes: 320, fingerprint: null },
            history_tool_result: { bytes: 840, fingerprint: null },
          },
        },
      })],
    } as Keeper

    render(html`<${CtxCompositionPanel} keeper=${keeper} />`, container)

    expect(container.textContent).toContain('attributed content bytes')
    expect(container.textContent).toContain('1,160 bytes')
    expect(container.textContent).toContain('provider input')
    expect(container.textContent).toContain('reported separately; not byte-attributed')
    expect(container.textContent).not.toContain('residual')
  })
})
