import { describe, it, expect } from 'vitest'
import { telemetrySourceLabel, telemetrySourceMeta, TELEMETRY_SOURCE_META } from './telemetry-sources'

// ================================================================
// telemetrySourceLabel
// ================================================================

describe('telemetrySourceLabel', () => {
  it('returns Korean label for keeper_metric', () => {
    expect(telemetrySourceLabel('keeper_metric')).toBe('Keeper 턴 로그')
  })

  it('returns Korean label for agent_event', () => {
    expect(telemetrySourceLabel('agent_event')).toBe('Agent 이벤트')
  })

  it('returns Korean label for tool_call_io', () => {
    expect(telemetrySourceLabel('tool_call_io')).toBe('Keeper Tool I/O')
  })

  it('returns Korean label for tool_usage', () => {
    expect(telemetrySourceLabel('tool_usage')).toBe('Keeper 내부 호출')
  })

  it('returns Korean label for oas_event', () => {
    expect(telemetrySourceLabel('oas_event')).toBe('OAS 이벤트')
  })

  it('returns Korean label for tool_metric', () => {
    expect(telemetrySourceLabel('tool_metric')).toBe('Tool 성능')
  })

  it('returns raw key for unknown source', () => {
    expect(telemetrySourceLabel('unknown_source')).toBe('unknown_source')
  })

  it('returns raw key for empty string', () => {
    expect(telemetrySourceLabel('')).toBe('')
  })
})

// ================================================================
// telemetrySourceMeta
// ================================================================

describe('telemetrySourceMeta', () => {
  it('returns meta for known source', () => {
    const meta = telemetrySourceMeta('keeper_metric')
    expect(meta.label).toBe('Keeper 턴 로그')
    expect(meta.icon).toBe('K')
    expect(meta.color).toBeTruthy()
  })

  it('returns all required fields for known sources', () => {
    for (const key of Object.keys(TELEMETRY_SOURCE_META)) {
      const meta = telemetrySourceMeta(key)
      expect(meta.label).toBeTruthy()
      expect(meta.sublabel).toBeDefined()
      expect(meta.color).toBeTruthy()
      expect(meta.icon).toBeTruthy()
    }
  })

  it('returns default for unknown source', () => {
    const meta = telemetrySourceMeta('custom')
    expect(meta.label).toBe('custom')
    expect(meta.sublabel).toBe('')
    expect(meta.icon).toBe('?')
  })

  it('returns default for empty string', () => {
    const meta = telemetrySourceMeta('')
    expect(meta.label).toBe('')
    expect(meta.icon).toBe('?')
  })
})
