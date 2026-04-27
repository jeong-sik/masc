import { describe, it, expect } from 'vitest'
import { approvalRiskToneClass, maxApprovalRisk } from './governance'

describe('approvalRiskToneClass', () => {
  it('returns bad tone for critical', () => {
    expect(approvalRiskToneClass('critical')).toBe('border-bad/30 bg-bad/10 text-bad')
  })

  it('returns warn tone for high', () => {
    expect(approvalRiskToneClass('high')).toBe('border-warn/30 bg-warn/10 text-warn')
  })

  it('returns accent tone for medium', () => {
    expect(approvalRiskToneClass('medium')).toBe('border-accent/30 bg-[var(--accent-10)] text-accent')
  })

  it('returns muted tone for low', () => {
    expect(approvalRiskToneClass('low')).toBe('border-[var(--white-10)] bg-[var(--white-3)] text-text-muted')
  })

  it('returns muted tone for unknown', () => {
    expect(approvalRiskToneClass('unknown')).toBe('border-[var(--white-10)] bg-[var(--white-3)] text-text-muted')
  })

  it('returns muted tone for empty string', () => {
    expect(approvalRiskToneClass('')).toBe('border-[var(--white-10)] bg-[var(--white-3)] text-text-muted')
  })

  it('is case-insensitive', () => {
    expect(approvalRiskToneClass('CRITICAL')).toBe('border-bad/30 bg-bad/10 text-bad')
    expect(approvalRiskToneClass('High')).toBe('border-warn/30 bg-warn/10 text-warn')
  })

  it('trims whitespace', () => {
    expect(approvalRiskToneClass('  medium  ')).toBe('border-accent/30 bg-[var(--accent-10)] text-accent')
  })
})

describe('maxApprovalRisk', () => {
  it('returns null for empty array', () => {
    expect(maxApprovalRisk([])).toBeNull()
  })

  it('returns the highest risk level', () => {
    const items = [{ risk_level: 'low' }, { risk_level: 'critical' }, { risk_level: 'medium' }]
    expect(maxApprovalRisk(items)).toBe('critical')
  })

  it('returns high when no critical present', () => {
    const items = [{ risk_level: 'low' }, { risk_level: 'high' }]
    expect(maxApprovalRisk(items)).toBe('high')
  })

  it('returns medium when only medium and low', () => {
    const items = [{ risk_level: 'low' }, { risk_level: 'medium' }]
    expect(maxApprovalRisk(items)).toBe('medium')
  })

  it('returns low when only low present', () => {
    const items = [{ risk_level: 'low' }]
    expect(maxApprovalRisk(items)).toBe('low')
  })

  it('returns null when all items have null risk', () => {
    const items = [{ risk_level: null }, { risk_level: undefined }]
    expect(maxApprovalRisk(items)).toBeNull()
  })

  it('returns null when all items have unknown risk', () => {
    const items = [{ risk_level: 'extreme' }]
    expect(maxApprovalRisk(items)).toBeNull()
  })

  it('handles items without risk_level field', () => {
    const items = [{}, { risk_level: 'high' }]
    expect(maxApprovalRisk(items)).toBe('high')
  })

  it('picks the first occurrence when tied', () => {
    const items = [{ risk_level: 'high' }, { risk_level: 'high' }]
    expect(maxApprovalRisk(items)).toBe('high')
  })
})
