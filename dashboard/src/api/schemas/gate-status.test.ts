import { describe, expect, it } from 'vitest'

import {
  GateStatusSchemaDriftError,
  parseGateStatusData,
} from './gate-status'

function validChannel(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    channel: 'slack',
    message_count: 42,
    ...overrides,
  }
}

function validBinding(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    channel: 'slack',
    room_id: 'C123',
    keeper: 'greeter',
    ...overrides,
  }
}

function validEvent(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    timestamp: '2026-04-17T00:00:00Z',
    channel: 'slack',
    room_id: 'C123',
    keeper: 'greeter',
    ...overrides,
  }
}

describe('parseGateStatusData', () => {
  it('accepts an empty response with all counts defaulting to 0', () => {
    const out = parseGateStatusData({})
    expect(out.channels).toHaveLength(0)
    expect(out.bindings).toHaveLength(0)
    expect(out.recent_events).toHaveLength(0)
    expect(out.total_messages).toBe(0)
    expect(out.uptime_seconds).toBe(0)
  })

  it('applies fallbacks on sparse channel entries', () => {
    const out = parseGateStatusData({
      channels: [validChannel()],
    })
    expect(out.channels).toHaveLength(1)
    expect(out.channels[0]!.channel).toBe('slack')
    expect(out.channels[0]!.success_count).toBe(0)
    expect(out.channels[0]!.health).toBe('idle')
    expect(out.channels[0]!.last_activity).toBe('')
  })

  it('drops channel rows missing the required channel field (lenient-per-entry)', () => {
    const out = parseGateStatusData({
      channels: [validChannel(), { message_count: 5 }],
    })
    expect(out.channels).toHaveLength(1)
  })

  it('drops binding rows missing any of channel/room_id/keeper', () => {
    const out = parseGateStatusData({
      bindings: [
        validBinding(),
        { channel: 'slack', room_id: 'C1' }, // missing keeper
        { channel: 'slack', keeper: 'k1' }, // missing room_id
      ],
    })
    expect(out.bindings).toHaveLength(1)
  })

  it('drops event rows missing timestamp', () => {
    const out = parseGateStatusData({
      recent_events: [
        validEvent(),
        { channel: 'slack', room_id: 'C1', keeper: 'k1' }, // missing timestamp
      ],
    })
    expect(out.recent_events).toHaveLength(1)
  })

  it('parses a fully-populated response', () => {
    const out = parseGateStatusData({
      channels: [validChannel({ message_count: 100, success_count: 95, health: 'healthy' })],
      bindings: [validBinding({ message_count: 50, success_count: 48 })],
      recent_events: [validEvent({ seq: 1, outcome: 'success', duration_ms: 120 })],
      total_messages: 100,
      total_success: 95,
      total_errors: 5,
      total_duplicates: 0,
      success_rate_pct: 95,
      dedup_table_size: 0,
      uptime_seconds: 3600,
    })
    expect(out.total_messages).toBe(100)
    expect(out.channels[0]!.success_count).toBe(95)
    expect(out.bindings[0]!.message_count).toBe(50)
    expect(out.recent_events[0]!.outcome).toBe('success')
  })

  it('tolerates non-array entries fields by returning empty lists', () => {
    const out = parseGateStatusData({ channels: null, bindings: 'oops', recent_events: {} })
    expect(out.channels).toHaveLength(0)
    expect(out.bindings).toHaveLength(0)
    expect(out.recent_events).toHaveLength(0)
  })

  it('throws on non-object payload', () => {
    expect(() => parseGateStatusData(null)).toThrow(GateStatusSchemaDriftError)
    expect(() => parseGateStatusData('oops')).toThrow(GateStatusSchemaDriftError)
  })
})
