import { describe, it, expect } from 'vitest'
import { flagTooltip, invariantDescription } from './fsm-hub-health-panels'

// ================================================================
// flagTooltip
// ================================================================

describe('flagTooltip', () => {
  // ── known flags with on=true ──

  it('returns handoff active tooltip', () => {
    const result = flagTooltip('handoff', true)
    expect(result).toContain('handoff')
    expect(result).toContain('active')
    expect(result).toContain('이관')
  })

  // ── known flags with on=false ──

  it('returns handoff inactive tooltip', () => {
    const result = flagTooltip('handoff', false)
    expect(result).toContain('inactive')
    expect(result).toContain('예약된 handoff 없음')
  })

  // ── unknown flag ──

  it('returns short tooltip for unknown flag active', () => {
    expect(flagTooltip('custom_flag', true)).toBe('custom_flag: active')
  })

  it('returns short tooltip for unknown flag inactive', () => {
    expect(flagTooltip('custom_flag', false)).toBe('custom_flag: inactive')
  })

  it('returns short tooltip for empty string label', () => {
    expect(flagTooltip('', true)).toBe(': active')
  })

  // ── format structure ──

  it('includes newline between status and description for known flag', () => {
    const result = flagTooltip('handoff', true)
    const parts = result.split('\n')
    expect(parts).toHaveLength(2)
    expect(parts[0]).toContain('handoff (active)')
    expect(parts[1]!.length).toBeGreaterThan(0)
  })

  it('has no newline for unknown flag', () => {
    const result = flagTooltip('unknown', true)
    expect(result).not.toContain('\n')
  })
})

// ================================================================
// invariantDescription
// ================================================================

describe('invariantDescription', () => {
  it('returns description for no_runtime_before_measurement', () => {
    const desc = invariantDescription('no_runtime_before_measurement')
    expect(desc).toContain('Runtime selection')
    expect(desc).toContain('measurement')
  })

  it('returns description for event_priority_monotone', () => {
    const desc = invariantDescription('event_priority_monotone')
    expect(desc).toContain('monotone')
    expect(desc).toContain('priority')
  })

  it('returns default for unknown key', () => {
    expect(invariantDescription('unknown_invariant')).toBe(
      'keeper composite contract 가 정의한 invariant.',
    )
  })

  it('returns default for empty string key', () => {
    expect(invariantDescription('')).toBe(
      'keeper composite contract 가 정의한 invariant.',
    )
  })

  it('all known descriptions are non-empty strings', () => {
    const keys = [
      'no_runtime_before_measurement',
      'event_priority_monotone',
    ]
    for (const key of keys) {
      const desc = invariantDescription(key)
      expect(desc.length).toBeGreaterThan(20)
    }
  })
})
