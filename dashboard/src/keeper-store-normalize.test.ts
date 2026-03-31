import { describe, expect, it } from 'vitest'
import { deriveLifecycleState, normalizeKeepers } from './keeper-store-normalize'

describe('normalizeKeepers lifecycle metrics', () => {
  it('accepts flat backend handoff fields', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'alpha',
        status: 'active',
        metrics_series: [
          {
            ts_unix: 1,
            context_ratio: 0.92,
            context_tokens: 920,
            context_max: 1000,
            latency_ms: 120,
            generation: 3,
            channel: 'turn',
            model_used: 'glm-5',
            cost_usd: 0.12,
            compacted: false,
            handoff_performed: true,
            handoff_to_model: 'glm-5',
            handoff_new_generation: 4,
          },
        ],
      },
    ])

    expect(keeper?.metrics_series).toHaveLength(1)
    const metric = keeper!.metrics_series![0]
    expect(metric).toMatchObject({
      is_handoff: true,
      is_compaction: false,
      handoff_to_model: 'glm-5',
      handoff_new_generation: 4,
    })
    expect(deriveLifecycleState(keeper!)).toBe('handoff-imminent')
  })

  it('accepts nested handoff objects with to_generation fallback', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'beta',
        status: 'active',
        metrics_series: [
          {
            ts_unix: 2,
            context_ratio: 0.88,
            context_tokens: 880,
            context_max: 1000,
            latency_ms: 140,
            generation: 5,
            channel: 'turn',
            model_used: 'gpt-5.4',
            cost_usd: 0.2,
            compacted: false,
            handoff: {
              performed: true,
              to_model: 'gpt-5.4',
              to_generation: 6,
            },
          },
        ],
      },
    ])

    expect(keeper?.metrics_series).toHaveLength(1)
    const metric = keeper!.metrics_series![0]
    expect(metric).toMatchObject({
      is_handoff: true,
      handoff_to_model: 'gpt-5.4',
      handoff_new_generation: 6,
    })
    expect(deriveLifecycleState(keeper!)).toBe('handoff-imminent')
  })

  it('marks compaction events as compacting', () => {
    const [keeper] = normalizeKeepers([
      {
        name: 'gamma',
        status: 'active',
        metrics_series: [
          {
            ts_unix: 3,
            context_ratio: 0.61,
            context_tokens: 610,
            context_max: 1000,
            latency_ms: 90,
            generation: 1,
            channel: 'turn',
            model_used: 'llama:auto',
            cost_usd: 0.01,
            compacted: true,
            compaction_saved_tokens: 240,
            compaction_trigger: 'ratio(0.9100>=0.8500)',
          },
        ],
      },
    ])

    expect(keeper?.metrics_series).toHaveLength(1)
    const metric = keeper!.metrics_series![0]
    expect(metric).toMatchObject({
      is_handoff: false,
      is_compaction: true,
      compaction_saved_tokens: 240,
      compaction_trigger: 'ratio(0.9100>=0.8500)',
    })
    expect(deriveLifecycleState(keeper!)).toBe('compacting')
  })
})
