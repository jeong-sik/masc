import { describe, expect, it } from 'vitest'
import type { TelemetryEntry } from '../../api/dashboard'
import {
  bucketTelemetryEntries, hourToMs, isToolCall, isToolCallFailure, toolCallName, toolCallOutcomeWord,
} from './observatory-utils'

describe('hourToMs', () => {
  it('parses the hour-precision bucket the tool-quality API sends', () => {
    // The exact shape of hourly_trend[].hour on /api/v1/dashboard/tool-quality.
    // Left unparsed it returns null, every point is filtered out, and the
    // success-rate track reads "hourly_trend 데이터 부족" against a store
    // holding 122k tool calls.
    expect(hourToMs('2026-08-18T07')).toBe(Date.parse('2026-08-18T07:00:00Z'))
  })

  it('passes a complete timestamp through unchanged', () => {
    expect(hourToMs('2026-08-18T07:00:00Z')).toBe(Date.parse('2026-08-18T07:00:00Z'))
  })

  it('returns null for a string it cannot read', () => {
    expect(hourToMs('not-a-time')).toBeNull()
  })
})

describe('bucketTelemetryEntries', () => {
  it('keeps the latest entry as the representative inside each bucket', () => {
    const windowStart = 0
    const windowEnd = 1_000
    const entries: TelemetryEntry[] = [
      { source: 'agent_event', timestamp: 100, event_type: 'early' },
      { source: 'agent_event', timestamp: 120, event_type: 'late' },
      { source: 'agent_event', timestamp: 900, event_type: 'tail' },
    ]

    const buckets = bucketTelemetryEntries(entries, windowStart, windowEnd, 10)

    expect(buckets).toHaveLength(2)
    expect(buckets[0]).toMatchObject({ count: 2, ts: 120 })
    expect(buckets[0]?.entry.event_type).toBe('late')
    expect(buckets[1]).toMatchObject({ count: 1, ts: 900 })
  })

  it('applies the optional predicate before bucketing', () => {
    const entries: TelemetryEntry[] = [
      { source: 'tool_usage', timestamp: 100, tool_name: 'ok', success: true },
      { source: 'tool_usage', timestamp: 110, tool_name: 'fail', success: false },
      { source: 'agent_event', timestamp: 120, event_type: 'ignored' },
    ]

    const buckets = bucketTelemetryEntries(entries, 0, 1_000, 10, isToolCall)

    expect(buckets).toHaveLength(1)
    expect(buckets[0]).toMatchObject({ count: 2, ts: 110 })
    expect(buckets[0]?.entry.tool_name).toBe('fail')
  })
})

describe('tool-call rows', () => {
  const row = (fields: Record<string, unknown>) => ({ ts: 1, ...fields }) as TelemetryEntry

  it('counts the tool-call log and the tool-usage log, and leaves lifecycle markers out', () => {
    expect(isToolCall(row({ source: 'tool_call_io', record_kind: 'tool_call' }))).toBe(true)
    expect(isToolCall(row({ source: 'tool_call_io', record_kind: 'composition_run' }))).toBe(true)
    expect(isToolCall(row({ source: 'tool_usage', disposition: 'completed' }))).toBe(true)
    expect(isToolCall(row({ source: 'tool_call_io', record_kind: 'lifecycle_event', wire_outcome: 'error' }))).toBe(false)
    expect(isToolCall(row({ source: 'agent_event' }))).toBe(false)
  })

  it('names the tool by `tool` on log rows and `tool_name` on usage rows', () => {
    expect(toolCallName(row({ source: 'tool_call_io', tool: 'tool_execute' }))).toBe('tool_execute')
    expect(toolCallName(row({ source: 'tool_usage', tool_name: 'masc_board_post' }))).toBe('masc_board_post')
    expect(toolCallName(row({ source: 'tool_usage' }))).toBe('?')
  })
})

describe('isToolCallFailure', () => {
  const row = (fields: Record<string, unknown>) => ({ ts: 1, ...fields }) as TelemetryEntry

  it('marks a row failed only by its recorded outcome, in either log', () => {
    expect(isToolCallFailure(row({ source: 'tool_call_io', disposition: 'failed' }))).toBe(true)
    expect(isToolCallFailure(row({ source: 'tool_call_io', wire_outcome: 'error' }))).toBe(true)
    expect(isToolCallFailure(row({ source: 'tool_usage', disposition: 'failed' }))).toBe(true)
    expect(isToolCallFailure(row({ source: 'tool_call_io', disposition: 'completed', wire_outcome: 'error' }))).toBe(false)
    expect(isToolCallFailure(row({ source: 'tool_usage', disposition: 'completed' }))).toBe(false)
  })

  it('does not guess a failure for a deferred, unsettled or malformed row', () => {
    for (const source of ['tool_call_io', 'tool_usage']) {
      for (const fields of [{ disposition: 'deferred' }, { disposition: 'invented' }, {}]) {
        // Even an error string beside the outcome does not turn it into a failure.
        expect(isToolCallFailure(row({ source, error: 'something', ...fields }))).toBe(false)
      }
    }
    expect(isToolCallFailure(row({ source: 'tool_call_io', wire_outcome: 'unknown' }))).toBe(false)
  })

  it('is not moved by a leftover success boolean', () => {
    expect(isToolCallFailure(row({ source: 'tool_call_io', success: false }))).toBe(false)
    expect(isToolCallFailure(row({ source: 'tool_usage', success: false }))).toBe(false)
  })

  it('never counts a lifecycle marker as a failure', () => {
    expect(isToolCallFailure(row({ source: 'tool_call_io', record_kind: 'lifecycle_event', wire_outcome: 'error' }))).toBe(false)
  })
})

describe('toolCallOutcomeWord', () => {
  const row = (fields: Record<string, unknown>) => ({ ts: 1, source: 'tool_call_io', ...fields }) as TelemetryEntry

  it('says ok only for a settled success; other outcomes keep their own name', () => {
    expect(toolCallOutcomeWord(row({ disposition: 'completed' }))).toBe('ok')
    expect(toolCallOutcomeWord(row({ disposition: 'failed' }))).toBe('failed')
    expect(toolCallOutcomeWord(row({ disposition: 'deferred' }))).toBe('deferred')
    expect(toolCallOutcomeWord(row({ wire_outcome: 'unknown' }))).toBe('unsettled')
    expect(toolCallOutcomeWord(row({ disposition: 'invented' }))).toBe('malformed')
  })
})
