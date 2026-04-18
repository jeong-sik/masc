import { describe, it, expect } from 'vitest'
import { PHASE_STYLES, getPhaseStyle } from './keeper-phase-indicator'

// ================================================================
// PHASE_STYLES
// ================================================================

describe('PHASE_STYLES', () => {
  it('has all 12 phases', () => {
    const phases = Object.keys(PHASE_STYLES)
    expect(phases).toHaveLength(12)
    expect(phases).toContain('Offline')
    expect(phases).toContain('Running')
    expect(phases).toContain('Failing')
    expect(phases).toContain('Overflowed')
    expect(phases).toContain('Compacting')
    expect(phases).toContain('HandingOff')
    expect(phases).toContain('Draining')
    expect(phases).toContain('Paused')
    expect(phases).toContain('Stopped')
    expect(phases).toContain('Crashed')
    expect(phases).toContain('Restarting')
    expect(phases).toContain('Dead')
  })

  it('each phase has label, color, bg, border, glow, icon', () => {
    for (const [_key, style] of Object.entries(PHASE_STYLES)) {
      expect(style).toHaveProperty('label')
      expect(style).toHaveProperty('color')
      expect(style).toHaveProperty('bg')
      expect(style).toHaveProperty('border')
      expect(style).toHaveProperty('glow')
      expect(style).toHaveProperty('icon')
      expect(typeof style.label).toBe('string')
      expect(typeof style.color).toBe('string')
    }
  })

  it('each label is Korean', () => {
    for (const style of Object.values(PHASE_STYLES)) {
      expect(style.label.length).toBeGreaterThan(0)
    }
  })

  it('color / bg / border reference design-system CSS variables', () => {
    // After #8235 + #8240 + the keeper-phase migration, hue values
    // live in tokens (ok / warn / accent / paused / bad-light /
    // text-muted) so paper theme can swap palettes without editing
    // this file. Hardcoded rgb / hex would reintroduce drift.
    for (const style of Object.values(PHASE_STYLES)) {
      expect(style.color).toMatch(/^var\(--/)
      expect(style.bg).toMatch(/^var\(--/)
      expect(style.border).toMatch(/^var\(--/)
    }
  })
})

// ================================================================
// getPhaseStyle
// ================================================================

describe('getPhaseStyle', () => {
  it('returns Offline for null', () => {
    expect(getPhaseStyle(null).label).toBe('오프라인')
  })

  it('returns Offline for undefined', () => {
    expect(getPhaseStyle(undefined).label).toBe('오프라인')
  })

  it('returns Offline for empty string', () => {
    expect(getPhaseStyle('').label).toBe('오프라인')
  })

  it('returns correct style for Running (ok group)', () => {
    const s = getPhaseStyle('Running')
    expect(s.label).toBe('실행중')
    expect(s.color).toBe('var(--ok)')
    expect(s.bg).toBe('var(--ok-10)')
  })

  it('returns correct style for Crashed (error group)', () => {
    const s = getPhaseStyle('Crashed')
    expect(s.label).toBe('비정상종료')
    expect(s.color).toBe('var(--bad-light)')
    expect(s.bg).toBe('var(--bad-10)')
  })

  it('Paused resolves to the paused (plum) token', () => {
    const s = getPhaseStyle('Paused')
    expect(s.label).toBe('일시정지')
    expect(s.color).toBe('var(--paused)')
  })

  it('Compacting / HandingOff / Draining / Restarting share the accent (slate/working) tone', () => {
    const tones = (['Compacting', 'HandingOff', 'Draining', 'Restarting'] as const).map(
      (p) => getPhaseStyle(p).color,
    )
    expect(new Set(tones).size).toBe(1)
    expect(tones[0]).toBe('var(--accent)')
  })

  it('returns Offline for unknown phase string', () => {
    expect(getPhaseStyle('UnknownPhase').label).toBe('오프라인')
  })

  it('returns correct style for all 12 phases', () => {
    const phases: string[] = ['Offline', 'Running', 'Failing', 'Overflowed', 'Compacting', 'HandingOff', 'Draining', 'Paused', 'Stopped', 'Crashed', 'Restarting', 'Dead']
    for (const phase of phases) {
      const style = getPhaseStyle(phase)
      expect(style.label).toBeTruthy()
      expect(style.color).toMatch(/^var\(--/)
    }
  })
})
