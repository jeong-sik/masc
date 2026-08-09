export const KEEPER_RESOLVED_APPROVAL_DECISIONS = [
  'approve',
  'reject',
] as const

export type KeeperResolvedApprovalDecision =
  typeof KEEPER_RESOLVED_APPROVAL_DECISIONS[number]

const KEEPER_RESOLVED_APPROVAL_DECISION_LABELS:
  Record<KeeperResolvedApprovalDecision, string> = {
    approve: '승인',
    reject: '거부',
  }

export function normalizeKeeperResolvedApprovalDecision(
  raw: string | null | undefined,
): KeeperResolvedApprovalDecision | null {
  if (raw === 'approve' || raw === 'reject') return raw
  return null
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
