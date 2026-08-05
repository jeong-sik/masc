import { afterEach, describe, expect, it } from 'vitest'

import {
  hydrateOasTelemetrySample,
  latestOasTelemetrySample,
} from './oas-telemetry-store'

function validTelemetryEvent(overrides: Record<string, unknown> = {}) {
  return {
    type: 'oas_telemetry_sample',
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
  latestOasTelemetrySample.value = null
})

describe('oas telemetry store', () => {
  it('hydrates the latest sample from the push payload without an HTTP fetch', () => {
    hydrateOasTelemetrySample(validTelemetryEvent())

    expect(latestOasTelemetrySample.value).toEqual({
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
    hydrateOasTelemetrySample(validTelemetryEvent())
    hydrateOasTelemetrySample(validTelemetryEvent({
      payload: {
        sample: {
          ttfb_ms: 90,
          total_duration_ms: 400,
          status: { kind: 'error', transient: true },
        },
        recorded_at: 1_712_000_001,
      },
    }))

    expect(latestOasTelemetrySample.value?.ttfb_ms).toBe(90)
    expect(latestOasTelemetrySample.value?.status_kind).toBe('error')
    expect(latestOasTelemetrySample.value?.throughput_tokens_per_s).toBeNull()
    expect(latestOasTelemetrySample.value?.recorded_at).toBe(1_712_000_001)
  })

  it('ignores malformed payloads instead of fabricating a sample', () => {
    hydrateOasTelemetrySample({ provider_id: 'runtime', payload: { recorded_at: 1 } })
    hydrateOasTelemetrySample({
      provider_id: 'runtime',
      payload: { sample: {}, recorded_at: 'bad' },
    })

    expect(latestOasTelemetrySample.value).toBeNull()
  })
})
