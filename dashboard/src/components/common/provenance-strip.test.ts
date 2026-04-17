import { describe, it, expect } from 'vitest'
import { provenanceTone, provenanceLabel } from './provenance-strip'

describe('provenanceTone', () => {
  it('returns ok for truth', () => {
    expect(provenanceTone('truth')).toBe('ok')
  })

  it('returns empty for recorded', () => {
    expect(provenanceTone('recorded')).toBe('')
  })

  it('returns warn for derived', () => {
    expect(provenanceTone('derived')).toBe('warn')
  })

  it('returns warn for fallback', () => {
    expect(provenanceTone('fallback')).toBe('warn')
  })

  it('returns warn for narrative', () => {
    expect(provenanceTone('narrative')).toBe('warn')
  })

  it('returns warn for judgment', () => {
    expect(provenanceTone('judgment')).toBe('warn')
  })

  it('returns empty for null', () => {
    expect(provenanceTone(null)).toBe('')
  })

  it('returns empty for undefined', () => {
    expect(provenanceTone(undefined)).toBe('')
  })

  it('returns empty for unknown value', () => {
    expect(provenanceTone('custom')).toBe('')
  })

  it('is case-insensitive', () => {
    expect(provenanceTone('TRUTH')).toBe('ok')
    expect(provenanceTone('Derived')).toBe('warn')
  })

  it('trims whitespace', () => {
    expect(provenanceTone('  truth  ')).toBe('ok')
  })
})

describe('provenanceLabel', () => {
  it('returns explicit label when present', () => {
    expect(provenanceLabel({ kind: 'truth', label: '커스텀' })).toBe('커스텀')
  })

  it('returns Korean label for truth', () => {
    expect(provenanceLabel({ kind: 'truth' })).toBe('검증됨')
  })

  it('returns Korean label for derived', () => {
    expect(provenanceLabel({ kind: 'derived' })).toBe('파생')
  })

  it('returns Korean label for fallback', () => {
    expect(provenanceLabel({ kind: 'fallback' })).toBe('대체값')
  })

  it('returns Korean label for narrative', () => {
    expect(provenanceLabel({ kind: 'narrative' })).toBe('서술')
  })

  it('returns Korean label for judgment', () => {
    expect(provenanceLabel({ kind: 'judgment' })).toBe('판단')
  })

  it('returns Korean label for recorded', () => {
    expect(provenanceLabel({ kind: 'recorded' })).toBe('기록됨')
  })

  it('returns unknown for empty kind', () => {
    expect(provenanceLabel({})).toBe('unknown')
  })

  it('returns raw kind when not in PROVENANCE_LABELS', () => {
    expect(provenanceLabel({ kind: 'custom' })).toBe('custom')
  })

  it('ignores whitespace-only label', () => {
    expect(provenanceLabel({ kind: 'truth', label: '   ' })).toBe('검증됨')
  })
})
