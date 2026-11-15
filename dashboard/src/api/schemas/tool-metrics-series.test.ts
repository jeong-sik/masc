import { describe, expect, it } from 'vitest'

import {
  parseToolMetricsSeriesResponse,
  seriesAnswerMismatch,
  toolMetricsSeriesQuery,
  type ToolMetricsSeriesRequest,
} from './tool-metrics-series'

const busy = {
  call_count: 2,
  failure_count: 1,
  failure_classes: {
    dependency_unavailable: 1,
    policy_rejection: 0,
    runtime_failure: 0,
    workflow_rejection: 0,
    operator_cancelled: 0,
  },
  failure_unclassified_count: 0,
  deferred_count: 0,
  total_ms: 90_030,
  p50_ms: 10,
  p95_ms: 20,
  max_ms: 90_000,
  long_count: 1,
  long_total_ms: 90_000,
  result_observed_count: 2,
  result_bytes_total: 5_000,
  result_bytes_max: 4_000,
}

// A bucket in which no call ran: the server sends null, never zero, for the
// three latency values, and zero for the long calls.
const idle = {
  call_count: 0,
  failure_count: 0,
  failure_classes: {
    dependency_unavailable: 0,
    policy_rejection: 0,
    runtime_failure: 0,
    workflow_rejection: 0,
    operator_cancelled: 0,
  },
  failure_unclassified_count: 0,
  deferred_count: 0,
  total_ms: 0,
  p50_ms: null,
  p95_ms: null,
  max_ms: null,
  long_count: 0,
  long_total_ms: 0,
  result_observed_count: 0,
  result_bytes_total: 0,
  result_bytes_max: null,
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
    long_call_ms: 60_000,
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

  it('keeps the line a long call starts at, and the long calls of every row', () => {
    const out = parseToolMetricsSeriesResponse(validResponse())
    expect(out.long_call_ms).toBe(60_000)
    expect([out.total, out.buckets[1], out.top_by_time[0]].map(row => row?.long_count)).toEqual([1, 1, 1])
    expect(out.buckets[1]?.long_total_ms).toBe(90_000)
  })

  it('keeps zero long calls for a bucket in which no call ran', () => {
    const idleBucket = parseToolMetricsSeriesResponse(validResponse()).buckets[0]
    expect([idleBucket?.long_count, idleBucket?.long_total_ms]).toEqual([0, 0])
  })

  it('rejects a bucket that lost its long calls, or an answer without the line', () => {
    const { long_count: _count, ...withoutLongCount } = busy
    expect(() =>
      parseToolMetricsSeriesResponse(validResponse({ buckets: [{ start: 1, ...withoutLongCount }] })),
    ).toThrow(/long_count/)
    const { long_total_ms: _time, ...withoutLongTime } = busy
    expect(() => parseToolMetricsSeriesResponse(validResponse({ total: withoutLongTime }))).toThrow(
      /long_total_ms/,
    )
    const { long_call_ms: _line, ...withoutLine } = validResponse()
    expect(() => parseToolMetricsSeriesResponse(withoutLine)).toThrow(/long_call_ms/)
  })

  it('keeps the result sizes of every row, and null for a set of calls without one', () => {
    const out = parseToolMetricsSeriesResponse(validResponse())
    expect([out.total, out.buckets[1], out.top_by_time[0]].map(row => row?.result_bytes_total)).toEqual([5_000, 5_000, 5_000])
    expect(out.buckets[1]?.result_bytes_max).toBe(4_000)
    const idleBucket = out.buckets[0]
    expect([idleBucket?.result_observed_count, idleBucket?.result_bytes_total, idleBucket?.result_bytes_max]).toEqual([0, 0, null])
  })

  it('rejects an answer from a server that does not send result sizes', () => {
    const { result_bytes_total: _bytes, ...withoutBytes } = busy
    expect(() => parseToolMetricsSeriesResponse(validResponse({ total: withoutBytes }))).toThrow(/result_bytes_total/)
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

describe('toolMetricsSeriesQuery', () => {
  it('names the parameters the server reads', () => {
    expect(toolMetricsSeriesQuery({ sinceHours: 168, bucket: 'hour', utcOffsetMin: -300, tool: null })).toBe(
      'since_hours=168&bucket=hour&utc_offset_min=-300',
    )
  })

  it('adds the tool filter, encoded', () => {
    expect(toolMetricsSeriesQuery({ sinceHours: 24, bucket: 'day', utcOffsetMin: 540, tool: 'a b&c' })).toBe(
      'since_hours=24&bucket=day&utc_offset_min=540&tool=a+b%26c',
    )
  })
})

// The server ignores a parameter it does not know and fills in a default. A
// response for another window than the one asked must not be charted under the
// asked window's label.
describe('seriesAnswerMismatch', () => {
  const asked: ToolMetricsSeriesRequest = { sinceHours: 24, bucket: 'hour', utcOffsetMin: 540, tool: null }
  const answer = (overrides: Record<string, unknown> = {}) =>
    parseToolMetricsSeriesResponse(validResponse(overrides))

  it('accepts the response for the request', () => {
    expect(seriesAnswerMismatch(asked, answer())).toBeNull()
  })

  it('accepts a window length that differs by float rounding only', () => {
    const response = answer()
    const rounded = { ...response, window: { ...response.window, since: response.window.since + 0.4 } }
    expect(seriesAnswerMismatch(asked, rounded)).toBeNull()
  })

  it('names a window of another length', () => {
    expect(seriesAnswerMismatch({ ...asked, sinceHours: 168 }, answer())).toContain('168')
  })

  it('names another bucket width, another offset and another tool', () => {
    expect(seriesAnswerMismatch({ ...asked, bucket: 'day' }, answer())).toContain('day')
    expect(seriesAnswerMismatch({ ...asked, utcOffsetMin: 0 }, answer())).toContain('UTC')
    expect(seriesAnswerMismatch({ ...asked, tool: 'tool_execute' }, answer())).toContain('tool_execute')
    expect(seriesAnswerMismatch(asked, answer({ tool: 'tool_execute' }))).toContain('tool_execute')
  })
})
