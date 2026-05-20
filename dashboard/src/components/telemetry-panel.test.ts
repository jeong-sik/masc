import { describe, it, expect } from 'vitest'

import { isTelemetryView } from './telemetry-panel'

describe('isTelemetryView', () => {
  it('returns true for each telemetry view key', () => {
    expect(isTelemetryView('cost')).toBe(true)
    expect(isTelemetryView('audit')).toBe(true)
    expect(isTelemetryView('heuristics')).toBe(true)
    expect(isTelemetryView('stress')).toBe(true)
  })

  it('returns false for primary runtime views', () => {
    expect(isTelemetryView('default')).toBe(false)
    expect(isTelemetryView('providers')).toBe(false)
    expect(isTelemetryView('inspector')).toBe(false)
  })

  it('returns false for raw / verification advanced views', () => {
    // prometheus and verification live next to telemetry on the Advanced
    // chip strip but are NOT routed through TelemetryPanel.
    expect(isTelemetryView('prometheus')).toBe(false)
    expect(isTelemetryView('verification')).toBe(false)
  })

  it('returns false for unknown strings (closed-set guard)', () => {
    expect(isTelemetryView('')).toBe(false)
    expect(isTelemetryView('cost-extra')).toBe(false)
    expect(isTelemetryView('audit ')).toBe(false)
    expect(isTelemetryView('COST')).toBe(false)
  })
})
