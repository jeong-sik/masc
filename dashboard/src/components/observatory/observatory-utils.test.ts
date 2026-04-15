import { describe, expect, it } from 'vitest'
import type { TelemetryEntry } from '../../api/dashboard'
import { bucketTelemetryEntries, isToolCall } from './observatory-utils'

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
