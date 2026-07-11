// Single derivation for "what needs the operator's attention" — computed
// once, consumed by both the nav rail (per-tab badge counts, NavRailV2) and
// the top-bar attention dropdown (drill-down rows, AttentionIndicatorV2).
// Before this module the same underlying signals (governanceData, keepers,
// staleKeepers) were re-derived independently in nav-rail-v2 (a 2-key closed
// record) and top-bar-v2 (computeAttention) — see the #65 nav-badge audit
// brief. Extending either surface now means adding a field here once.
//
// Every rail tab must have a decision (0 allowed, but stated): the
// `satisfies NavBadges` check below is exhaustive over RailBadgeTab, so
// adding a surface to nav-rail-v2.ts's SURFACES is a compile error here until
// this module states what that tab's badge count is.

import { computed, type ReadonlySignal } from '@preact/signals'
import { keepers, messages, shellAuthSummary, staleKeepers, tasksByStatus } from './store'
import { governanceData } from './components/governance-signals'
import { toolsData } from './components/tools/tool-state'
import { scheduledPendingApprovalCount } from './components/tools/scheduled-automation-panel'
import { buildMentionInboxModel, mentionTargetCandidates } from './components/board/mention-inbox'
import { currentDashboardActorName } from './lib/dashboard-session-actor'
import { markBoardMentionsSeen, unseenMentionCount } from './board-mentions-last-seen'
import type { NavBadges } from './components/v2/nav-rail-v2'

// Keeper lifecycle phases treated as "needs operator intervention" — moved
// here from top-bar-v2.ts (single definition; top-bar re-imports it).
export const DEAD_KEEPER_PHASES = new Set(['Overflowed', 'Crashed', 'Dead', 'Zombie'])

export interface AttentionBreakdown {
  approvals: number
  needsAttentionKeepers: number
  deadKeepers: number
  staleKeepers: number
  boardMentionsForMe: number
  awaitingVerification: number
  schedulePending: number
}

// KNOWN LIMITATION (documented, not silently propagated — see PR body /
// #65 audit): `staleKeepers` is keeper *heartbeat* staleness
// (store.ts HEARTBEAT_STALE_MS), not connector-*gate* staleness
// (GateConnectorInfo.stale in connector-status.ts, which is only fetched
// when the Connectors surface itself mounts — not a route-independent
// signal). The pre-existing top-bar-v2 attention dropdown has labeled this
// count "stale 게이트" and routed it to the connectors tab since it was
// introduced; this module preserves that exact mapping (no new backend
// aggregation) rather than inventing a fix here. Flagged as a follow-up.
export const attentionBreakdown: ReadonlySignal<AttentionBreakdown> = computed(() => {
  const ks = keepers.value
  const targets = mentionTargetCandidates(shellAuthSummary.value, currentDashboardActorName())
  const mentionModel = buildMentionInboxModel(messages.value, targets)
  return {
    approvals: governanceData.value?.approval_queue?.length ?? 0,
    needsAttentionKeepers: ks.filter(k => k.needs_attention === true).length,
    deadKeepers: ks.filter(k => !!k.lifecycle_phase && DEAD_KEEPER_PHASES.has(k.lifecycle_phase)).length,
    staleKeepers: staleKeepers.value.size,
    boardMentionsForMe: unseenMentionCount(mentionModel.forMe),
    awaitingVerification: tasksByStatus.value.awaitingVerification.length,
    schedulePending: scheduledPendingApprovalCount(toolsData.value?.scheduled_automation ?? null),
  }
})

// Explicit zeros, decided (brief #65 "Kill or keep"): overview and settings
// have no attention semantics; monitoring's fleet detail already lives in the
// health strip; fusion runs are informational, not attention; logs already
// has its own dedicated top-bar ErrorCounterBadge (a second projection of
// unacknowledgedCount here would violate SSOT); code/IDE has no live source.
export const navBadges: ReadonlySignal<NavBadges> = computed(() => {
  const a = attentionBreakdown.value
  return {
    overview: 0,
    keepers: a.needsAttentionKeepers + a.deadKeepers,
    monitoring: 0,
    workspace: a.awaitingVerification,
    approvals: a.approvals,
    schedule: a.schedulePending,
    board: a.boardMentionsForMe,
    fusion: 0,
    logs: 0,
    code: 0,
    connectors: a.staleKeepers,
    settings: 0,
  } satisfies NavBadges
})

/** Advance the board-mentions cursor to the newest currently-known for-me
 *  mention. Call on board-route visit (app.ts) — the same "mark read on
 *  visit" shape as advanceKeeperLastSeen, just app-root-driven instead of
 *  panel-mount-driven since the board surface itself is out of scope here. */
export function markBoardMentionsSeenNow(): void {
  const targets = mentionTargetCandidates(shellAuthSummary.value, currentDashboardActorName())
  const model = buildMentionInboxModel(messages.value, targets)
  markBoardMentionsSeen(model.forMe)
}
