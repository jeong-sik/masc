import type { GovernanceDecisionItem } from '../types'

export type GovernanceFilter = 'open' | 'pending_ruling' | 'needs_human_gate' | 'executed' | 'blocked'

export function itemKey(item: GovernanceDecisionItem): string {
  return `${item.kind}:${item.id}`
}

export function getSelectedDecision(
  selectedKey: string | null,
  items: GovernanceDecisionItem[],
): GovernanceDecisionItem | null {
  if (!selectedKey) return null
  return items.find(item => itemKey(item) === selectedKey) ?? null
}

export function isOpenStatus(status: string): boolean {
  const normalized = status.trim().toLowerCase()
  return normalized !== 'executed' && normalized !== 'blocked' && normalized !== 'closed'
}

export function filteredItemsByFilter(filter: GovernanceFilter, items: GovernanceDecisionItem[]): GovernanceDecisionItem[] {
  switch (filter) {
    case 'pending_ruling':
      return items.filter(item => item.status === 'pending_ruling')
    case 'needs_human_gate':
      return items.filter(item => item.status === 'needs_human_gate')
    case 'executed':
      return items.filter(item => item.status === 'executed')
    case 'blocked':
      return items.filter(item => item.status === 'blocked' || item.status === 'closed')
    case 'open':
    default:
      return items.filter(item => isOpenStatus(item.status))
  }
}

export function serializePreview(value: unknown): string {
  if (value == null) return '없음'
  if (typeof value === 'string') return value
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return String(value)
  }
}

export function caseStatusLabel(value: string | null | undefined): string {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'pending':
    case 'pending_ruling':
      return '판정 대기'
    case 'ready_auto_execute':
      return '자동집행 준비'
    case 'needs_human_gate':
      return '승인 대기'
    case 'executed':
      return '집행 완료'
    case 'blocked':
      return '보류'
    case 'closed':
      return '종결'
    default:
      return value?.trim() || '확인 필요'
  }
}

export function orderStatusLabel(value: string | null | undefined): string {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'queued_auto':
      return '자동 대기'
    case 'needs_human_gate':
      return '승인 대기'
    case 'auto_executed':
      return '자동 집행됨'
    case 'done':
      return '완료'
    case 'denied':
      return '거부됨'
    case 'blocked':
      return '보류'
    case 'none':
      return '없음'
    default:
      return value?.trim() || '없음'
  }
}

export function stanceLabel(value: string): string {
  switch (value) {
    case 'support':
      return '찬성'
    case 'oppose':
      return '반대'
    case 'neutral':
      return '중립'
    default:
      return value
  }
}

export function kindLabel(value: string): string {
  switch (value) {
    case 'case':
      return '사건'
    case 'petition':
      return '청원'
    default:
      return value
  }
}

export function activityKindLabel(value: string): string {
  switch (value) {
    case 'petition_submitted':
      return '청원 접수'
    case 'brief_submitted':
      return '의견 제출'
    case 'ruling_issued':
      return '판정 발행'
    case 'execution_order':
      return '집행 명령'
    default:
      return value
  }
}

export function confidenceText(confidence: number | null | undefined): string {
  if (typeof confidence !== 'number' || Number.isNaN(confidence)) return '판정 대기'
  return `${Math.round(confidence * 100)}%`
}

export function formatAgeSummary(seconds: number | null | undefined): string | null {
  if (seconds == null) return null
  if (seconds < 3600) return `${Math.floor(seconds / 60)}분`
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}시간`
  return `${Math.floor(seconds / 86400)}일`
}

export function formatParamValue(value: unknown): string {
  if (value === null || value === undefined) return '-'
  if (typeof value === 'string') return value
  if (typeof value === 'number') return String(value)
  if (typeof value === 'boolean') return value ? 'true' : 'false'
  return JSON.stringify(value)
}
