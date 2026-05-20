import type { GovernanceDecisionItem } from '../types'
import { SECONDS_PER_HOUR, SECONDS_PER_DAY, SECONDS_PER_MINUTE } from '../lib/format-time'

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
  if (seconds < SECONDS_PER_HOUR) return `${Math.floor(seconds / SECONDS_PER_MINUTE)}m`
  if (seconds < SECONDS_PER_DAY) return `${Math.floor(seconds / SECONDS_PER_HOUR)}h`
  return `${Math.floor(seconds / SECONDS_PER_DAY)}d`
}
