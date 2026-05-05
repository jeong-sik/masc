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

function isOpenStatus(status: string): boolean {
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

export function kindLabel(value: string): string {
  switch (value) {
    case 'case':
      return 'Case'
    case 'petition':
      return 'Petition'
    default:
      return value
  }
}

export function formatAgeSummary(seconds: number | null | undefined): string | null {
  if (seconds == null) return null
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`
  return `${Math.floor(seconds / 86400)}d`
}
