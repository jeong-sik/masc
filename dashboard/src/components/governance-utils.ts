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

/**
 * Governance-domain kind → 표시용 라벨.
 *
 * Distinct from `kindLabel(kind: string)` in `board/board-state.ts`:
 *   - Governance enum: `'case' | 'petition'` → 영어 capitalize (`'Case'`/`'Petition'`)
 *   - Board enum: `'direct' | 'automation' | 'system'` → 한국어 (`'직접'` 등)
 *
 * 같은 함수명에 *완전히 다른 enum + 다른 출력 언어* 가 매핑되어 있어
 * import 사이트에서 잘못된 변형을 부르면 governance UI 가 한국어 board
 * 라벨로 회귀 (또는 그 반대). Renamed from `kindLabel` to
 * `governanceKindLabel` on 2026-05-27 — 이름에 도메인을 박아 SSOT
 * collision 폐쇄.
 */
export function governanceKindLabel(value: string): string {
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
