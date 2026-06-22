import { describe, expect, it } from 'vitest'
import {
  asKeeperApprovalRiskLevel,
  keeperApprovalRiskLabel,
  keeperApprovalRiskVisualBand,
  maxKeeperApprovalRiskLevel,
} from './governance-risk-level'

describe('keeperApprovalRiskLabel', () => {
  it('maps each closed risk-level value to its Korean label', () => {
    expect(keeperApprovalRiskLabel('critical')).toBe('심각')
    expect(keeperApprovalRiskLabel('high')).toBe('높음')
    expect(keeperApprovalRiskLabel('medium')).toBe('보통')
    expect(keeperApprovalRiskLabel('low')).toBe('낮음')
  })

  it('parses case-insensitively via the shared closed-set parser', () => {
    expect(keeperApprovalRiskLabel('CRITICAL')).toBe('심각')
    expect(keeperApprovalRiskLabel('  High  ')).toBe('높음')
  })

  it('shows unknown / unparseable input as 미분류 rather than the raw string', () => {
    expect(keeperApprovalRiskLabel(null)).toBe('미분류')
    expect(keeperApprovalRiskLabel(undefined)).toBe('미분류')
    expect(keeperApprovalRiskLabel('')).toBe('미분류')
    // A raw enum leak that is not a risk level is not silently prettified.
    expect(keeperApprovalRiskLabel('completion_contract_result:passive_only')).toBe('미분류')
  })

  it('stays aligned with the visual band parser on the same input', () => {
    // Both helpers route through asKeeperApprovalRiskLevel, so a value that
    // parses to a band also parses to a non-미분류 label.
    expect(asKeeperApprovalRiskLevel('high')).toBe('high')
    expect(keeperApprovalRiskVisualBand('high')).toBe('warn')
    expect(keeperApprovalRiskLabel('high')).toBe('높음')
  })
})

describe('keeperApprovalRiskVisualBand', () => {
  it('maps each closed level through the shared SSOT', () => {
    expect(keeperApprovalRiskVisualBand('critical')).toBe('bad')
    expect(keeperApprovalRiskVisualBand('high')).toBe('warn')
    expect(keeperApprovalRiskVisualBand('medium')).toBe('accent')
    expect(keeperApprovalRiskVisualBand('low')).toBe('info')
  })

  it('falls back to info for unparseable input', () => {
    expect(keeperApprovalRiskVisualBand(null)).toBe('info')
    expect(keeperApprovalRiskVisualBand('nope')).toBe('info')
  })
})

describe('maxKeeperApprovalRiskLevel', () => {
  it('returns the highest-rank level from the SSOT ordering', () => {
    expect(
      maxKeeperApprovalRiskLevel([
        { risk_level: 'low' },
        { risk_level: 'critical' },
        { risk_level: 'medium' },
      ]),
    ).toBe('critical')
  })

  it('ignores unparseable rows and returns null when none parse', () => {
    expect(
      maxKeeperApprovalRiskLevel([{ risk_level: 'nope' }, { risk_level: null }]),
    ).toBe(null)
    expect(maxKeeperApprovalRiskLevel([])).toBe(null)
  })
})
