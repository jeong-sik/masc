import { describe, it, expect } from 'vitest'
import {
  itemKey,
  getSelectedDecision,
  isOpenStatus,
  filteredItemsByFilter,
  serializePreview,
  caseStatusLabel,
  orderStatusLabel,
  stanceLabel,
  kindLabel,
  activityKindLabel,
  confidenceText,
  formatAgeSummary,
  formatParamValue,
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

describe('serializePreview', () => {
  it('returns "없음" for null', () => {
    expect(serializePreview(null)).toBe('없음')
  })

  it('returns "없음" for undefined', () => {
    expect(serializePreview(undefined)).toBe('없음')
  })

  it('returns string as-is', () => {
    expect(serializePreview('hello')).toBe('hello')
  })

  it('serializes object to pretty JSON', () => {
    expect(serializePreview({ a: 1 })).toBe('{\n  "a": 1\n}')
  })

  it('serializes array to pretty JSON', () => {
    expect(serializePreview([1, 2])).toBe('[\n  1,\n  2\n]')
  })

  it('handles number via JSON.stringify', () => {
    expect(serializePreview(42)).toBe('42')
  })
})

// ================================================================
// caseStatusLabel
// ================================================================

describe('caseStatusLabel', () => {
  it('returns "판정 대기" for pending', () => {
    expect(caseStatusLabel('pending')).toBe('판정 대기')
  })

  it('returns "판정 대기" for pending_ruling', () => {
    expect(caseStatusLabel('pending_ruling')).toBe('판정 대기')
  })

  it('returns "자동집행 준비" for ready_auto_execute', () => {
    expect(caseStatusLabel('ready_auto_execute')).toBe('자동집행 준비')
  })

  it('returns "승인 대기" for needs_human_gate', () => {
    expect(caseStatusLabel('needs_human_gate')).toBe('승인 대기')
  })

  it('returns "집행 완료" for executed', () => {
    expect(caseStatusLabel('executed')).toBe('집행 완료')
  })

  it('returns "보류" for blocked', () => {
    expect(caseStatusLabel('blocked')).toBe('보류')
  })

  it('returns "종결" for closed', () => {
    expect(caseStatusLabel('closed')).toBe('종결')
  })

  it('returns raw value for unknown status', () => {
    expect(caseStatusLabel('custom_status')).toBe('custom_status')
  })

  it('returns "확인 필요" for null', () => {
    expect(caseStatusLabel(null)).toBe('확인 필요')
  })

  it('returns "확인 필요" for undefined', () => {
    expect(caseStatusLabel(undefined)).toBe('확인 필요')
  })

  it('returns "확인 필요" for empty string', () => {
    expect(caseStatusLabel('')).toBe('확인 필요')
  })

  it('is case-insensitive', () => {
    expect(caseStatusLabel('Executed')).toBe('집행 완료')
    expect(caseStatusLabel('BLOCKED')).toBe('보류')
  })
})

// ================================================================
// orderStatusLabel
// ================================================================

describe('orderStatusLabel', () => {
  it('returns "자동 대기" for queued_auto', () => {
    expect(orderStatusLabel('queued_auto')).toBe('자동 대기')
  })

  it('returns "승인 대기" for needs_human_gate', () => {
    expect(orderStatusLabel('needs_human_gate')).toBe('승인 대기')
  })

  it('returns "자동 집행됨" for auto_executed', () => {
    expect(orderStatusLabel('auto_executed')).toBe('자동 집행됨')
  })

  it('returns "완료" for done', () => {
    expect(orderStatusLabel('done')).toBe('완료')
  })

  it('returns "거부됨" for denied', () => {
    expect(orderStatusLabel('denied')).toBe('거부됨')
  })

  it('returns "보류" for blocked', () => {
    expect(orderStatusLabel('blocked')).toBe('보류')
  })

  it('returns "없음" for none', () => {
    expect(orderStatusLabel('none')).toBe('없음')
  })

  it('returns raw value for unknown', () => {
    expect(orderStatusLabel('custom')).toBe('custom')
  })

  it('returns "없음" for null', () => {
    expect(orderStatusLabel(null)).toBe('없음')
  })

  it('returns "없음" for empty string', () => {
    expect(orderStatusLabel('')).toBe('없음')
  })
})

// ================================================================
// stanceLabel
// ================================================================

describe('stanceLabel', () => {
  it('returns "찬성" for support', () => {
    expect(stanceLabel('support')).toBe('찬성')
  })

  it('returns "반대" for oppose', () => {
    expect(stanceLabel('oppose')).toBe('반대')
  })

  it('returns "중립" for neutral', () => {
    expect(stanceLabel('neutral')).toBe('중립')
  })

  it('returns raw value for unknown', () => {
    expect(stanceLabel('custom')).toBe('custom')
  })
})

// ================================================================
// kindLabel
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

describe('activityKindLabel', () => {
  it('returns "청원 접수" for petition_submitted', () => {
    expect(activityKindLabel('petition_submitted')).toBe('청원 접수')
  })

  it('returns "의견 제출" for brief_submitted', () => {
    expect(activityKindLabel('brief_submitted')).toBe('의견 제출')
  })

  it('returns "판정 발행" for ruling_issued', () => {
    expect(activityKindLabel('ruling_issued')).toBe('판정 발행')
  })

  it('returns "집행 명령" for execution_order', () => {
    expect(activityKindLabel('execution_order')).toBe('집행 명령')
  })

  it('returns raw value for unknown', () => {
    expect(activityKindLabel('custom')).toBe('custom')
  })
})

// ================================================================
// confidenceText
// ================================================================

describe('confidenceText', () => {
  it('returns percentage for valid number', () => {
    expect(confidenceText(0.85)).toBe('85%')
  })

  it('rounds to nearest percent', () => {
    expect(confidenceText(0.855)).toBe('86%')
  })

  it('returns 100% for 1.0', () => {
    expect(confidenceText(1.0)).toBe('100%')
  })

  it('returns 0% for 0', () => {
    expect(confidenceText(0)).toBe('0%')
  })

  it('returns "판정 대기" for null', () => {
    expect(confidenceText(null)).toBe('판정 대기')
  })

  it('returns "판정 대기" for undefined', () => {
    expect(confidenceText(undefined)).toBe('판정 대기')
  })

  it('returns "판정 대기" for NaN', () => {
    expect(confidenceText(NaN)).toBe('판정 대기')
  })
})

// ================================================================
// formatAgeSummary
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

describe('formatParamValue', () => {
  it('returns "-" for null', () => {
    expect(formatParamValue(null)).toBe('-')
  })

  it('returns "-" for undefined', () => {
    expect(formatParamValue(undefined)).toBe('-')
  })

  it('returns string as-is', () => {
    expect(formatParamValue('hello')).toBe('hello')
  })

  it('converts number to string', () => {
    expect(formatParamValue(42)).toBe('42')
  })

  it('converts boolean true', () => {
    expect(formatParamValue(true)).toBe('true')
  })

  it('converts boolean false', () => {
    expect(formatParamValue(false)).toBe('false')
  })

  it('serializes objects to JSON', () => {
    expect(formatParamValue({ key: 'val' })).toBe('{"key":"val"}')
  })

  it('serializes arrays to JSON', () => {
    expect(formatParamValue([1, 2])).toBe('[1,2]')
  })
})
