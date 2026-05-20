import { describe, it, expect } from 'vitest'

import {
  isTelemetryView,
  TELEMETRY_VIEW_CHIPS,
  type TelemetryView,
} from './telemetry-panel'

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

describe('TELEMETRY_VIEW_CHIPS', () => {
  it('exposes exactly the four telemetry view keys', () => {
    const keys = TELEMETRY_VIEW_CHIPS.map(chip => chip.key)
    expect(keys).toEqual(['cost', 'audit', 'heuristics', 'stress'])
  })

  it('every chip key passes isTelemetryView (round-trip consistency)', () => {
    for (const chip of TELEMETRY_VIEW_CHIPS) {
      expect(isTelemetryView(chip.key)).toBe(true)
    }
  })

  it('every chip carries a non-empty Korean label', () => {
    for (const chip of TELEMETRY_VIEW_CHIPS) {
      expect(chip.label.length).toBeGreaterThan(0)
    }
  })

  it('TelemetryView type narrows out CostView keys that telemetry-panel does not render', () => {
    // Pin the assignment direction: TelemetryView ⊆ chip key set,
    // chip key set ⊆ TelemetryView. If CostView ever extends with a key
    // that telemetry-panel should also render, this assignment will fail.
    const allowed: TelemetryView[] = TELEMETRY_VIEW_CHIPS.map(chip => chip.key)
    expect(allowed).toHaveLength(TELEMETRY_VIEW_CHIPS.length)
  })
})
