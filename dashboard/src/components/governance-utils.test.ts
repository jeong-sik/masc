import { describe, it, expect } from 'vitest'
import {
  itemKey,
  getSelectedDecision,
  isOpenStatus,
  filteredItemsByFilter,
  kindLabel,
  formatAgeSummary,
} from './governance-utils'
import type { GovernanceDecisionItem } from '../types'

function makeItem(overrides: Partial<GovernanceDecisionItem> = {}): GovernanceDecisionItem {
  return {
    id: 'item-1',
    kind: 'case',
    topic: 'test topic',
    status: 'pending_ruling',
    confidence: 0.85,
    related_agents: [],
    evidence_refs: [],
    ...overrides,
  }
}

// ================================================================
// itemKey
// ================================================================

describe('itemKey', () => {
  it('returns kind:id format', () => {
    expect(itemKey(makeItem({ kind: 'case', id: '42' }))).toBe('case:42')
  })

  it('handles petition kind', () => {
    expect(itemKey(makeItem({ kind: 'petition', id: '99' }))).toBe('petition:99')
  })
})

// ================================================================
// getSelectedDecision
// ================================================================

describe('getSelectedDecision', () => {
  const items = [
    makeItem({ id: '1', kind: 'case', status: 'pending_ruling' }),
    makeItem({ id: '2', kind: 'petition', status: 'executed' }),
  ]

  it('returns null for null selectedKey', () => {
    expect(getSelectedDecision(null, items)).toBeNull()
  })

  it('returns matching item', () => {
    const result = getSelectedDecision('case:1', items)
    expect(result).not.toBeNull()
    expect(result!.id).toBe('1')
  })

  it('returns null for non-matching key', () => {
    expect(getSelectedDecision('case:99', items)).toBeNull()
  })

  it('returns null for empty array', () => {
    expect(getSelectedDecision('case:1', [])).toBeNull()
  })
})

// ================================================================
// isOpenStatus
// ================================================================

describe('isOpenStatus', () => {
  it('returns true for pending_ruling', () => {
    expect(isOpenStatus('pending_ruling')).toBe(true)
  })

  it('returns true for needs_human_gate', () => {
    expect(isOpenStatus('needs_human_gate')).toBe(true)
  })

  it('returns true for unknown status', () => {
    expect(isOpenStatus('something_else')).toBe(true)
  })

  it('returns false for executed', () => {
    expect(isOpenStatus('executed')).toBe(false)
  })

  it('returns false for blocked', () => {
    expect(isOpenStatus('blocked')).toBe(false)
  })

  it('returns false for closed', () => {
    expect(isOpenStatus('closed')).toBe(false)
  })

  it('is case-insensitive', () => {
    expect(isOpenStatus('Executed')).toBe(false)
    expect(isOpenStatus('BLOCKED')).toBe(false)
  })

  it('trims whitespace', () => {
    expect(isOpenStatus('  executed  ')).toBe(false)
  })
})

// ================================================================
// filteredItemsByFilter
// ================================================================

describe('filteredItemsByFilter', () => {
  const items = [
    makeItem({ id: '1', status: 'pending_ruling' }),
    makeItem({ id: '2', status: 'needs_human_gate' }),
    makeItem({ id: '3', status: 'executed' }),
    makeItem({ id: '4', status: 'blocked' }),
    makeItem({ id: '5', status: 'closed' }),
  ]

  it('filters pending_ruling', () => {
    const result = filteredItemsByFilter('pending_ruling', items)
    expect(result).toHaveLength(1)
    expect(result[0]!.id).toBe('1')
  })

  it('filters needs_human_gate', () => {
    const result = filteredItemsByFilter('needs_human_gate', items)
    expect(result).toHaveLength(1)
    expect(result[0]!.id).toBe('2')
  })

  it('filters executed', () => {
    const result = filteredItemsByFilter('executed', items)
    expect(result).toHaveLength(1)
    expect(result[0]!.id).toBe('3')
  })

  it('filters blocked and closed together', () => {
    const result = filteredItemsByFilter('blocked', items)
    expect(result).toHaveLength(2)
    expect(result.map(i => i.id)).toEqual(['4', '5'])
  })

  it('open filter returns non-executed/non-blocked/non-closed', () => {
    const result = filteredItemsByFilter('open', items)
    expect(result).toHaveLength(2)
    expect(result.map(i => i.id)).toEqual(['1', '2'])
  })

  it('returns open items for unknown filter value', () => {
    const result = filteredItemsByFilter('unknown_filter' as any, items)
    expect(result).toHaveLength(2)
  })
})

// ================================================================
// serializePreview
// ================================================================

describe('kindLabel', () => {
  it('returns "사건" for case', () => {
    expect(kindLabel('case')).toBe('사건')
  })

  it('returns "청원" for petition', () => {
    expect(kindLabel('petition')).toBe('청원')
  })

  it('returns raw value for unknown', () => {
    expect(kindLabel('custom')).toBe('custom')
  })
})

// ================================================================
// activityKindLabel
// ================================================================

describe('formatAgeSummary', () => {
  it('returns null for null', () => {
    expect(formatAgeSummary(null)).toBeNull()
  })

  it('returns null for undefined', () => {
    expect(formatAgeSummary(undefined)).toBeNull()
  })

  it('formats minutes for < 3600 seconds', () => {
    expect(formatAgeSummary(120)).toBe('2분')
    expect(formatAgeSummary(3599)).toBe('59분')
  })

  it('formats hours for < 86400 seconds', () => {
    expect(formatAgeSummary(3600)).toBe('1시간')
    expect(formatAgeSummary(86399)).toBe('23시간')
  })

  it('formats days for >= 86400 seconds', () => {
    expect(formatAgeSummary(86400)).toBe('1일')
    expect(formatAgeSummary(172800)).toBe('2일')
  })

  it('handles 0 seconds', () => {
    expect(formatAgeSummary(0)).toBe('0분')
  })
})

// ================================================================
// formatParamValue
// ================================================================

