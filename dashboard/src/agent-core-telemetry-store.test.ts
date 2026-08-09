import { afterEach, describe, expect, it } from 'vitest'

import {
  hydrateAgentCoreTelemetrySample,
  latestAgentCoreTelemetrySample,
} from './agent-core-telemetry-store'

function validTelemetryEvent(overrides: Record<string, unknown> = {}) {
  return {
    type: 'agent_core_telemetry_sample',
    provider_id: 'runtime',
    model_id: 'runtime',
    payload: {
      sample: {
        ttfb_ms: 120.5,
        total_duration_ms: 845.2,
        throughput_tokens_per_s: 42.1,
        cost_usd: 0.003,
        status: { kind: 'success' },
      },
      recorded_at: 1_712_000_000.5,
    },
    ts_unix: 1_712_000_000.5,
    ...overrides,
  }
}

afterEach(() => {
  latestAgentCoreTelemetrySample.value = null
})

describe('agentCore telemetry store', () => {
  it('hydrates the latest sample from the push payload without an HTTP fetch', () => {
    hydrateAgentCoreTelemetrySample(validTelemetryEvent())

    expect(latestAgentCoreTelemetrySample.value).toEqual({
      provider_id: 'runtime',
      model_id: 'runtime',
      ttfb_ms: 120.5,
      total_duration_ms: 845.2,
      throughput_tokens_per_s: 42.1,
      cost_usd: 0.003,
      status_kind: 'success',
      recorded_at: 1_712_000_000.5,
    })
  })

  it('replaces the previous sample with the newest push', () => {
    hydrateAgentCoreTelemetrySample(validTelemetryEvent())
    hydrateAgentCoreTelemetrySample(validTelemetryEvent({
      payload: {
        sample: {
          ttfb_ms: 90,
          total_duration_ms: 400,
          status: { kind: 'error', transient: true },
        },
        recorded_at: 1_712_000_001,
      },
    }))

    expect(latestAgentCoreTelemetrySample.value?.ttfb_ms).toBe(90)
    expect(latestAgentCoreTelemetrySample.value?.status_kind).toBe('error')
    expect(latestAgentCoreTelemetrySample.value?.throughput_tokens_per_s).toBeNull()
    expect(latestAgentCoreTelemetrySample.value?.recorded_at).toBe(1_712_000_001)
  })

  it('ignores malformed payloads instead of fabricating a sample', () => {
    hydrateAgentCoreTelemetrySample({ provider_id: 'runtime', payload: { recorded_at: 1 } })
    hydrateAgentCoreTelemetrySample({
      provider_id: 'runtime',
      payload: { sample: {}, recorded_at: 'bad' },
    })

    expect(latestAgentCoreTelemetrySample.value).toBeNull()
  })
})
