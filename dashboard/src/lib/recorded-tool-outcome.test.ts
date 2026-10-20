import { describe, expect, it } from 'vitest'
import { recordedToolOutcome, telemetryToolOutcome } from './recorded-tool-outcome'

describe('recordedToolOutcome', () => {
  it('lets a present disposition decide, whatever the wire says', () => {
    expect(recordedToolOutcome({ disposition: 'completed', wire_outcome: 'error' })).toBe('succeeded')
    expect(recordedToolOutcome({ disposition: 'failed', wire_outcome: 'ok' })).toBe('failed')
    expect(recordedToolOutcome({ disposition: 'deferred', wire_outcome: 'ok' })).toBe('deferred')
    expect(recordedToolOutcome({ disposition: 'invented', wire_outcome: 'ok' })).toBe('malformed')
    expect(recordedToolOutcome({ disposition: null, wire_outcome: 'ok' })).toBe('malformed')
  })

  it('falls back to the wire outcome only when there is no disposition', () => {
    expect(recordedToolOutcome({ wire_outcome: 'ok' })).toBe('succeeded')
    expect(recordedToolOutcome({ wire_outcome: 'error' })).toBe('failed')
    expect(recordedToolOutcome({ wire_outcome: 'unknown' })).toBe('unsettled')
    expect(recordedToolOutcome({ wire_outcome: 'invented' })).toBe('malformed')
  })

  it('grants no outcome to a leftover boolean or to a row with neither field', () => {
    expect(recordedToolOutcome({ success: true })).toBe('unsettled')
    expect(recordedToolOutcome({ success: false })).toBe('unsettled')
    expect(recordedToolOutcome({})).toBe('unsettled')
  })
})

describe('telemetryToolOutcome', () => {
  it('reads a tool_call_io row through the recorded rule, never through success', () => {
    expect(telemetryToolOutcome({ source: 'tool_call_io', disposition: 'failed' })).toBe('failed')
    expect(telemetryToolOutcome({ source: 'tool_call_io', wire_outcome: 'ok' })).toBe('succeeded')
    expect(telemetryToolOutcome({ source: 'tool_call_io', success: true })).toBe('unsettled')
    expect(telemetryToolOutcome({ source: 'tool_call_io', success: false, wire_outcome: 'ok' })).toBe('succeeded')
  })

  it('reads a tool_usage row the same way: it carries a disposition, never a success', () => {
    expect(telemetryToolOutcome({ source: 'tool_usage', disposition: 'completed' })).toBe('succeeded')
    expect(telemetryToolOutcome({ source: 'tool_usage', disposition: 'failed' })).toBe('failed')
    expect(telemetryToolOutcome({ source: 'tool_usage', disposition: 'deferred' })).toBe('deferred')
    expect(telemetryToolOutcome({ source: 'tool_usage', disposition: 'invented' })).toBe('malformed')
    expect(telemetryToolOutcome({ source: 'tool_usage', success: true })).toBe('unsettled')
  })

  it('gives a lifecycle marker no outcome, whatever else it carries', () => {
    expect(telemetryToolOutcome({ source: 'tool_call_io', record_kind: 'lifecycle_event', wire_outcome: 'error' })).toBeNull()
    expect(telemetryToolOutcome({ source: 'tool_call_io', record_kind: 'lifecycle_event', disposition: 'failed' })).toBeNull()
  })

  it('keeps the boolean contract of every other producer', () => {
    expect(telemetryToolOutcome({ source: 'agent_event', success: true })).toBe('succeeded')
    expect(telemetryToolOutcome({ source: 'agent_event', success: false })).toBe('failed')
  })

  it('reports no outcome when another producer carries no boolean', () => {
    expect(telemetryToolOutcome({ source: 'agent_event' })).toBeNull()
    expect(telemetryToolOutcome({ source: 'agent_event', success: 'yes' })).toBeNull()
    expect(telemetryToolOutcome({ source: 'agent_event', disposition: 'failed' })).toBeNull()
  })
})
