// Typed blocker-reason derivation for a keeper.
//
// Background: `keeper-detail-runtime.ts` derived the *blocker reason*
// row through a 3-fallback chain that mixed three semantically distinct
// fields:
//
//   composite?.runtime_attention?.reason
//   ?? keeper.runtime_blocker_summary
//   ?? keeper.attention_reason
//   ?? null
//
// Priority order:
//   1. `composite.runtime_attention.reason`   — observer-recorded reason
//   2. `keeper.runtime_blocker_summary`       — flat blocker-class summary
//   3. `keeper.attention_reason`              — flat attention memo
//
// The chain is *semantically reasonable* but loses provenance: when the
// dashboard says "차단: foo", an operator cannot tell whether `foo`
// came from the observer, the flat blocker, or the flat attention
// memo. Same `??` short-circuit semantic concern as
// `lib/keeper-fiber-alive.ts` — empty-string values used to fall
// through silently because `??` only halts on null/undefined, but the
// caller's `compactToken` collapses empty strings into the
// "no blocker reason" fallback anyway.
//
// This module makes that decision explicit and preserves the source.

import type { Keeper } from '../types'
import type { KeeperCompositeSnapshot } from '../api/schemas/keeper-composite'

export type BlockerReasonSource =
  | 'composite_runtime_attention'
  | 'flat_runtime_blocker_summary'
  | 'flat_attention_reason'
  | 'none'

export interface BlockerReasonDecision {
  /** Trimmed reason text, or `null` when no source produced a
   *  non-empty value. Callers typically project this with a
   *  "no blocker reason" placeholder. */
  readonly reason: string | null
  readonly source: BlockerReasonSource
}

interface BlockerReasonInput {
  readonly keeper: Pick<Keeper, 'runtime_blocker_summary' | 'attention_reason'>
  readonly composite: KeeperCompositeSnapshot | null
}

function trimToNonEmpty(value: string | null | undefined): string | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  return trimmed === '' ? null : trimmed
}

export function deriveBlockerReason({
  keeper,
  composite,
}: BlockerReasonInput): BlockerReasonDecision {
  const fromComposite = trimToNonEmpty(composite?.runtime_attention?.reason)
  if (fromComposite !== null) {
    return { reason: fromComposite, source: 'composite_runtime_attention' }
  }
  const fromBlockerSummary = trimToNonEmpty(keeper.runtime_blocker_summary)
  if (fromBlockerSummary !== null) {
    return { reason: fromBlockerSummary, source: 'flat_runtime_blocker_summary' }
  }
  const fromAttentionReason = trimToNonEmpty(keeper.attention_reason)
  if (fromAttentionReason !== null) {
    return { reason: fromAttentionReason, source: 'flat_attention_reason' }
  }
  return { reason: null, source: 'none' }
}
