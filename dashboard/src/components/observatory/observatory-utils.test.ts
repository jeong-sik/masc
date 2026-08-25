import { describe, expect, it } from 'vitest'
import type { TelemetryEntry } from '../../api/dashboard'
import { bucketTelemetryEntries, hourToMs, isToolCall } from './observatory-utils'

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
