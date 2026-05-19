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
