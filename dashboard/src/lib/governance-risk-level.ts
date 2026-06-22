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

interface RiskLevelMeta {
  readonly label: string
  readonly band: KeeperApprovalRiskVisualBand
  readonly rank: number
}

// Single source of truth, keyed by the closed `KeeperApprovalRiskLevel` union.
//
// This is what makes the exhaustiveness *compiler-enforced* rather than merely
// asserted by a hand-written switch: `satisfies Record<KeeperApprovalRiskLevel,
// …>` requires a key for EVERY union member (a missing key is a compile error,
// independent of tsconfig flags like noImplicitReturns). A hand-listed Set or a
// per-function switch only enforces a subset, so adding a backend risk level
// could silently fall through to 미분류 / 'info' without a build failure. Every
// derived view below (parser vocabulary, label, visual band, ordering rank)
// reads from this one object, so a new risk level forces an update here once.
const RISK_LEVEL_META = {
  critical: { label: '심각', band: 'bad', rank: 4 },
  high: { label: '높음', band: 'warn', rank: 3 },
  medium: { label: '보통', band: 'accent', rank: 2 },
  low: { label: '낮음', band: 'info', rank: 1 },
} as const satisfies Record<KeeperApprovalRiskLevel, RiskLevelMeta>

// Shown (not hidden or prettified) when input does not parse to a closed level.
const UNCLASSIFIED_LABEL = '미분류'
const UNCLASSIFIED_BAND: KeeperApprovalRiskVisualBand = 'info'

// Parser vocabulary derived from the SSOT keys, so it cannot drift from the
// label/band/rank views above.
const RISK_LEVEL_VALUES: ReadonlySet<string> = new Set(Object.keys(RISK_LEVEL_META))

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
  const level = asKeeperApprovalRiskLevel(value)
  return level === null ? UNCLASSIFIED_BAND : RISK_LEVEL_META[level].band
}

// Human-readable Korean label for a governance risk level. Reads from the
// `RISK_LEVEL_META` SSOT, so a new backend risk level is a compile error at the
// SSOT (above) rather than a silent fall-through to a raw wire string here.
// Unknown / unparseable input renders as 미분류 (shown, not hidden or prettified).
export function keeperApprovalRiskLabel(value: unknown): string {
  const level = asKeeperApprovalRiskLevel(value)
  return level === null ? UNCLASSIFIED_LABEL : RISK_LEVEL_META[level].label
}

export function isHighOrCriticalKeeperApprovalRisk(value: unknown): boolean {
  const level = asKeeperApprovalRiskLevel(value)
  return level === 'critical' || level === 'high'
}

export function maxKeeperApprovalRiskLevel(
  items: readonly { risk_level?: string | null }[],
): KeeperApprovalRiskLevel | null {
  let topRank = 0
  let topLabel: KeeperApprovalRiskLevel | null = null
  for (const item of items) {
    const level = asKeeperApprovalRiskLevel(item.risk_level)
    const rank = level === null ? 0 : RISK_LEVEL_META[level].rank
    if (rank > topRank) {
      topRank = rank
      topLabel = level
    }
  }
  return topLabel
}
