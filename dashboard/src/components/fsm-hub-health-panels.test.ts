import { describe, it, expect } from 'vitest'
import { flagTooltip, invariantDescription } from './fsm-hub-health-panels'

// ================================================================
// flagTooltip
// ================================================================

describe('flagTooltip', () => {
  // ── known flags with on=true ──

  it('returns reflect active tooltip', () => {
    const result = flagTooltip('reflect', true)
    expect(result).toContain('reflect')
    expect(result).toContain('active')
    expect(result).toContain('Reflexion loop')
  })

  it('returns plan active tooltip', () => {
    const result = flagTooltip('plan', true)
    expect(result).toContain('plan')
    expect(result).toContain('active')
    expect(result).toContain('재계획')
  })

  it('returns compact active tooltip', () => {
    const result = flagTooltip('compact', true)
    expect(result).toContain('compact')
    expect(result).toContain('active')
    expect(result).toContain('압축')
  })

  it('returns handoff active tooltip', () => {
    const result = flagTooltip('handoff', true)
    expect(result).toContain('handoff')
    expect(result).toContain('active')
    expect(result).toContain('이관')
  })

  it('returns guardrail active tooltip', () => {
    const result = flagTooltip('guardrail', true)
    expect(result).toContain('guardrail')
    expect(result).toContain('active')
    expect(result).toContain('guardrail 발동됨')
  })

  // ── known flags with on=false ──

  it('returns reflect inactive tooltip', () => {
    const result = flagTooltip('reflect', false)
    expect(result).toContain('reflect')
    expect(result).toContain('inactive')
    expect(result).toContain('예약된 reflection 없음')
  })

  it('returns plan inactive tooltip', () => {
    const result = flagTooltip('plan', false)
    expect(result).toContain('inactive')
    expect(result).toContain('예약된 재계획 없음')
  })

  it('returns compact inactive tooltip', () => {
    const result = flagTooltip('compact', false)
    expect(result).toContain('inactive')
    expect(result).toContain('예약된 압축 없음')
  })

  it('returns handoff inactive tooltip', () => {
    const result = flagTooltip('handoff', false)
    expect(result).toContain('inactive')
    expect(result).toContain('예약된 handoff 없음')
  })

  it('returns guardrail inactive tooltip', () => {
    const result = flagTooltip('guardrail', false)
    expect(result).toContain('inactive')
    expect(result).toContain('활성 guardrail 없음')
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
    const result = flagTooltip('reflect', true)
    const parts = result.split('\n')
    expect(parts).toHaveLength(2)
    expect(parts[0]).toContain('reflect (active)')
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
  it('returns description for phase_turn_alignment', () => {
    const desc = invariantDescription('phase_turn_alignment')
    expect(desc).toContain('KSM phase')
    expect(desc).toContain('Running')
  })

  it('returns description for no_cascade_before_measurement', () => {
    const desc = invariantDescription('no_cascade_before_measurement')
    expect(desc).toContain('Cascade selection')
    expect(desc).toContain('measurement')
  })

  it('returns description for compaction_atomicity', () => {
    const desc = invariantDescription('compaction_atomicity')
    expect(desc).toContain('atomic')
    expect(desc).toContain('half-compacted')
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
      'phase_turn_alignment',
      'no_cascade_before_measurement',
      'compaction_atomicity',
      'event_priority_monotone',
    ]
    for (const key of keys) {
      const desc = invariantDescription(key)
      expect(desc.length).toBeGreaterThan(20)
    }
  })
})
