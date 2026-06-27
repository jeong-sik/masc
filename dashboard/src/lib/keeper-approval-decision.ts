export const KEEPER_RESOLVED_APPROVAL_DECISIONS = [
  'approve',
  'reject',
  'edit',
  'unknown',
] as const

export type KeeperResolvedApprovalDecision =
  typeof KEEPER_RESOLVED_APPROVAL_DECISIONS[number]

const KEEPER_RESOLVED_APPROVAL_DECISION_LABELS:
  Record<KeeperResolvedApprovalDecision, string> = {
    approve: '승인',
    reject: '거부',
    edit: '수정됨',
    unknown: '처리됨',
  }

export function normalizeKeeperResolvedApprovalDecision(
  raw: string | null | undefined,
): KeeperResolvedApprovalDecision {
  const value = raw?.trim()
  if (value === 'approve') return 'approve'
  if (value === 'reject' || value?.startsWith('reject:')) return 'reject'
  if (value === 'edit') return 'edit'
  return 'unknown'
}

export function keeperResolvedApprovalDecisionLabel(
  decision: KeeperResolvedApprovalDecision,
): string {
  return KEEPER_RESOLVED_APPROVAL_DECISION_LABELS[decision]
}

export function keeperResolvedApprovalDecisionClass(
  decision: KeeperResolvedApprovalDecision,
): string {
  return `decision-${decision}`
}
