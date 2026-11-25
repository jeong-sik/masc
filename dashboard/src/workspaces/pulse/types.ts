/**
 * Pulse Workspace wire models.
 */

import type { Observed } from '../../core/resource-cache'
import type uPlot from 'uplot'

export interface PulseTurnSlot {
  readonly starts_at: number
  readonly ok: number
  readonly rested: number
  readonly failed: number
  readonly scheduled: number
  readonly reacted: number
  readonly chat: number
  readonly own: number
  readonly unknown: number
}

export interface PulseKeeperPathRest {
  readonly status: 'serving' | 'resting'
  readonly runtime_id: string | null
  readonly release_at: string | null
  readonly release_basis: string | null
}

export interface PulseKeeperLaneFailure {
  readonly runtime_id: string | null
  readonly summary: string
  readonly fault_kind: string | null
}

export interface PulseKeeperRow {
  readonly name: string
  readonly status: string
  readonly phase: string
  readonly health: string
  readonly paused: boolean
  readonly keepalive_running: boolean
  readonly runtime_id: string
  readonly sandbox_profile: string | null
  readonly context_ratio: number | null
  readonly context_tokens: number | null
  readonly context_max: number | null
  readonly context_provenance?: 'measured' | 'estimated' | 'unavailable' | null
  readonly estimated_context_ratio?: number | null
  readonly context_unavailable_reason: string | null
  readonly next_action: string | null
  readonly runtime_blocker_summary: string | null
  readonly runtime_blocker_signature?: string | null
  readonly runtime_path_rest?: PulseKeeperPathRest | null
  readonly operator_disposition?: string | null
  readonly operator_disposition_reason?: string | null
  readonly failing_since?: number | null
  readonly runtime_lane_failures?: readonly PulseKeeperLaneFailure[]
  readonly last_failure: { readonly cause: string; readonly at_unix: number | null } | null
  readonly recent_turns: { readonly known_since: number; readonly slots: readonly PulseTurnSlot[] } | null
  readonly candle_balance_milli: string | number | null
  readonly directory_issue?: string | null
}

export interface PulseShellGroup {
  readonly group: string
  readonly keeper_count: number
  readonly keepers: readonly string[]
}

export interface PulseShellSnapshot {
  readonly generated_at: string | null
  readonly project: string | null
  readonly version: string | null
  readonly counts: {
    readonly agents: number | null
    readonly tasks: number | null
    readonly tasks_done_24h: number | null
    readonly keepers: number | null
    readonly configured_keepers: number | null
    readonly total_runtimes: number | null
  }
  readonly scorecard: {
    readonly tasks_done_24h: number | null
    readonly tasks_awaiting_verification: number | null
    readonly tasks_in_progress: number | null
    readonly turns_24h: number | null
    readonly cost_24h_usd: number | null
    readonly verifications_passed_24h: number | null
    readonly verifications_rejected_24h: number | null
    readonly goals_completed_24h: number | null
  }
  readonly groups: readonly PulseShellGroup[]
}

export interface PulseKeeperCostRow {
  readonly keeper_name: string
  readonly total_cost_usd: number | null
  readonly cost_reported_samples: number
  readonly cost_unreported_samples: number
  readonly total_tokens: number | null
  readonly sample_count: number
}

export interface PulseProviderUsagePoint {
  readonly scope_id: string
  readonly source: string
  readonly kind: string
  readonly unit: string
  readonly value: number | null
  readonly limit: number | null
  readonly remaining: number | null
}

export type PulseProviderUsageSnapshot =
  | { readonly state: 'unavailable'; readonly reason: string }
  | { readonly state: 'available'; readonly days: number; readonly points: readonly PulseProviderUsagePoint[] }

export interface PulseApprovalItem {
  readonly approval_id: string
  readonly keeper: string
  readonly tool_call_id: string
  readonly tool: string
  readonly question: string
  readonly asked_at: number | null
}

export interface PulseAskItem {
  readonly ask_id: string
  readonly keeper: string
  readonly summary: string
  readonly created_at: number | null
  readonly question_count: number
}

export interface PulseGoalSummary {
  readonly id: string
  readonly title: string
  readonly phase: string
  readonly task_count: number
  readonly task_done_count: number
  readonly awaiting_verification_count: number
  readonly pending_approval_count: number
  readonly verification_status: string | null
  readonly linked_keeper_names: readonly string[]
  readonly updated_at: string | null
}

export interface PulseBoardPost {
  readonly id: string
  readonly title: string
  readonly body: string
  readonly author: string
  readonly hearth: string | null
  readonly created_at: string | null
  readonly reply_count: number
  readonly mentions: readonly string[]
  readonly succession_parent_id: string | null
}

export interface PulseWorldMemoryDigest {
  readonly source: string | null
  readonly ledger_state: 'available' | 'missing'
  readonly claims_count: number
  readonly facts_count: number
  readonly conflicts_count: number
  readonly briefing_status: string
  readonly briefing_text: string | null
  readonly wiki_count: number | null
  readonly artifact_count: number | null
}

export interface PulseCandleDigest {
  readonly ledger_state: 'missing' | 'present'
  readonly total_events: number
  readonly policy_configuration: 'off' | 'disabled' | 'enabled'
  readonly disabled_reason: string | null
  readonly pricing_mode: string
  readonly half_life_hours: number | null
  readonly issued_milli: string
  readonly burned_milli: string
  readonly circulating_milli: string
  readonly active_keepers: number
}

export type SpendClassification =
  | {
      readonly kind: 'reported'
      readonly usd: number
      readonly subscriptionCount: number
      readonly exhaustedCount: number
      readonly unreportedCount: number
    }
  | { readonly kind: 'subscription_zero'; readonly subscriptionCount: number; readonly exhaustedCount: number }
  | { readonly kind: 'exhausted_zero'; readonly exhaustedCount: number }
  | { readonly kind: 'unreported'; readonly reason: string }
  | { readonly kind: 'absent' }

export interface PulseKpiCard {
  readonly id: 'active_keepers' | 'tasks_24h' | 'turns_24h' | 'spend_24h'
  readonly label: string
  readonly value: Observed<string>
  readonly exactTooltip: string | null
  readonly secondary: string | null
  readonly tone: 'default' | 'ok' | 'warn' | 'bad' | 'brass'
  readonly route: string
}

export type AttentionSeverity = 'critical' | 'warn' | 'info'

export interface PulseAttentionItem {
  readonly id: string
  readonly kind: 'approval' | 'ask' | 'keeper_failure'
  readonly severity: AttentionSeverity
  readonly keeper: string
  readonly title: string
  readonly detail: string
  readonly ageSec: number | null
  readonly route: string
  readonly raw: unknown
}

export interface PulseFleetGroup {
  readonly company: string
  readonly keepers: readonly PulseKeeperRow[]
  readonly activeCount: number
  readonly failingCount: number
  readonly restingCount?: number
  readonly turnsInWindow: number
  readonly okTurnsInWindow?: number
  readonly restedTurnsInWindow?: number
  readonly failedTurnsInWindow?: number
  readonly sparklineData: uPlot.AlignedData
  readonly window: '24h'
}

export interface PulseHandoffItem {
  readonly id: string
  readonly fromKeeper: string
  readonly toKeepers: readonly string[]
  readonly kind: 'handoff' | 'succession' | 'collab'
  readonly title: string
  readonly hearth: string | null
  readonly replyCount: number
  readonly createdAt: string | null
  readonly route: string
}
