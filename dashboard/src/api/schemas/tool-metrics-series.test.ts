import { describe, expect, it } from 'vitest'

import { parseToolMetricsSeriesResponse } from './tool-metrics-series'

const busy = {
  call_count: 2,
  failure_count: 1,
  deferred_count: 0,
  total_ms: 30,
  p50_ms: 10,
  p95_ms: 20,
  max_ms: 20,
}

// A bucket in which no call ran: the server sends null, never zero, for the
// three latency values.
const idle = {
  call_count: 0,
  failure_count: 0,
  deferred_count: 0,
  total_ms: 0,
  p50_ms: null,
  p95_ms: null,
  max_ms: null,
}

function validResponse(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    generated_at: 1_793_811_969,
    source: { kind: 'tool_metrics', persistence: 'sqlite' },
    window: {
      since: 1_793_725_569,
      until: 1_793_811_969,
      bucket: 'hour',
      bucket_seconds: 3600,
      utc_offset_min: 540,
    },
    tool: null,
    total: busy,
    buckets: [
      { start: 1_793_804_400, ...idle },
      { start: 1_793_808_000, ...busy },
    ],
    top_by_time: [{ name: 'tool_execute', public_names: ['Execute'], ...busy }],
    ...overrides,
  }
}

describe('parseToolMetricsSeriesResponse', () => {
  it('accepts a well-formed response', () => {
    const out = parseToolMetricsSeriesResponse(validResponse())
    expect(out.buckets).toHaveLength(2)
    expect(out.top_by_time[0]?.public_names).toEqual(['Execute'])
    expect(out.window.bucket).toBe('hour')
  })

  it('keeps null latency for a bucket in which no call ran', () => {
    const out = parseToolMetricsSeriesResponse(validResponse())
    expect(out.buckets[0]?.p95_ms).toBeNull()
    expect(out.buckets[1]?.p95_ms).toBe(20)
  })

  it('keeps the tool filter the server echoed', () => {
    expect(parseToolMetricsSeriesResponse(validResponse({ tool: 'tool_execute' })).tool).toBe('tool_execute')
  })

  it('rejects a bucket width the server does not send', () => {
    const response = validResponse()
    expect(() =>
      parseToolMetricsSeriesResponse({
        ...response,
        window: { ...(response.window as object), bucket: 'week' },
      }),
    ).toThrow()
  })

  it('rejects a bucket that lost a count', () => {
    const { call_count: _omitted, ...withoutCount } = busy
    expect(() =>
      parseToolMetricsSeriesResponse(validResponse({ buckets: [{ start: 1, ...withoutCount }] })),
    ).toThrow(/call_count/)
  })

  it('names the drifted field in the error', () => {
    expect(() =>
      parseToolMetricsSeriesResponse(validResponse({ total: { ...busy, failure_count: 'many' } })),
    ).toThrow(/failure_count/)
  })

  it('rejects a number that is not finite', () => {
    expect(() =>
      parseToolMetricsSeriesResponse(validResponse({ total: { ...busy, total_ms: Number.NaN } })),
    ).toThrow(/total_ms/)
  })

  it('ignores fields it does not know, so the server can add them first', () => {
    const out = parseToolMetricsSeriesResponse(validResponse({ extra: true }))
    expect('extra' in out).toBe(false)
  })
})
