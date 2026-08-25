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

// The design tones a resolved row by outcome: the row carries `dec-<tone>` for
// its left stripe and the decision text carries the bare tone. A Record keyed by
// the decision union makes the mapping total, so adding a third decision fails
// the build here rather than falling through to an untoned row.
const KEEPER_RESOLVED_APPROVAL_DECISION_TONES:
  Record<KeeperResolvedApprovalDecision, 'ok' | 'bad'> = {
    approve: 'ok',
    reject: 'bad',
  }

export function keeperResolvedApprovalDecisionTone(
  decision: KeeperResolvedApprovalDecision,
): 'ok' | 'bad' {
  return KEEPER_RESOLVED_APPROVAL_DECISION_TONES[decision]
}
