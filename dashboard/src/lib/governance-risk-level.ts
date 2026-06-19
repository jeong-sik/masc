// Typed parsers for governance risk-level wire strings.
//
// Backend SSOT:
//   `lib/governance_pipeline_types.ml:1-18` —
//     type risk_level = Low | Medium | High | Critical
//   `risk_level_to_string` serializes to {low, medium, high, critical}.
// Same vocabulary at `lib/keeper/keeper_approval_queue.ml:49-53, :814`.
//
// Companion to `lib/runtime-blocker-class.ts` and
// `lib/keeper-runtime-state.ts` — same boundary-hardening pattern.

import type { KeeperApprovalRiskLevel } from '../types/governance'

export type KeeperApprovalRiskVisualBand = 'bad' | 'warn' | 'accent' | 'info'

const RISK_LEVEL_VALUES: ReadonlySet<string> = new Set([
  'low',
  'medium',
  'high',
  'critical',
] satisfies readonly KeeperApprovalRiskLevel[])

export function isKeeperApprovalRiskLevel(
  value: string,
): value is KeeperApprovalRiskLevel {
  return RISK_LEVEL_VALUES.has(value)
}

export function asKeeperApprovalRiskLevel(
  value: unknown,
): KeeperApprovalRiskLevel | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim().toLowerCase()
  if (trimmed === '') return null
  return isKeeperApprovalRiskLevel(trimmed) ? trimmed : null
}

export function keeperApprovalRiskVisualBand(value: unknown): KeeperApprovalRiskVisualBand {
  switch (asKeeperApprovalRiskLevel(value)) {
    case 'critical':
      return 'bad'
    case 'high':
      return 'warn'
    case 'medium':
      return 'accent'
    case 'low':
    case null:
      return 'info'
  }
}

export function isHighOrCriticalKeeperApprovalRisk(value: unknown): boolean {
  const level = asKeeperApprovalRiskLevel(value)
  return level === 'critical' || level === 'high'
}

const RISK_RANK: Record<KeeperApprovalRiskLevel, number> = {
  critical: 4,
  high: 3,
  medium: 2,
  low: 1,
}

export function maxKeeperApprovalRiskLevel(
  items: readonly { risk_level?: string | null }[],
): KeeperApprovalRiskLevel | null {
  let topRank = 0
  let topLabel: KeeperApprovalRiskLevel | null = null
  for (const item of items) {
    const level = asKeeperApprovalRiskLevel(item.risk_level)
    const rank = level ? RISK_RANK[level] : 0
    if (rank > topRank) {
      topRank = rank
      topLabel = level
    }
  }
  return topLabel
}
