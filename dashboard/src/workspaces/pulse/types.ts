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
  readonly attempt?: number | null
  readonly dispatch?: string | null
  readonly failure_kind?: string | null
  readonly failure_detail?: string | null
  readonly provider?: string | null
  readonly network_kind?: string | null
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
  readonly runtime_blocker_class?: string | null
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

/**
 * One reading of a provider usage window, as `utilization_fields`
 * (lib/runtime/runtime_provider_usage_window.ml) writes it. A unit the
 * server does not write is not decoded into one of these.
 */
export type PulseUsageUtilization =
  | { readonly unit: 'fraction'; readonly value: number }
  | { readonly unit: 'percent'; readonly value: number }
  | { readonly unit: 'usd'; readonly value: number; readonly limit: number | null }
  | { readonly unit: 'credit_balance'; readonly remaining: number }
  | { readonly unit: 'credit_unlimited' }

export interface PulseProviderUsagePoint {
  readonly scope_id: string
  readonly source: string
  readonly kind: string
  readonly limit_id: string | null
  /** Unix seconds the provider reported this reading. */
  readonly observed_at: number
  /** Unix seconds the window resets; `null` when the provider did not say. */
  readonly resets_at: number | null
  readonly utilization: PulseUsageUtilization
}

export interface PulseReportedNoWindows {
  readonly scope_id: string
  readonly observed_at: number
}

export type PulseProviderUsageSnapshot =
  | { readonly state: 'unavailable'; readonly reason: string }
  | {
      readonly state: 'available'
      readonly days: number
      readonly points: readonly PulseProviderUsagePoint[]
      /** Scope-days whose latest report stated no window at all. */
      readonly reported_no_windows: readonly PulseReportedNoWindows[]
      /** Points the decoder could not read (missing identity, time, or unit). */
      readonly undecodable_points: number
    }

/** Whether a provider window refuses calls at `now`, read from its latest reading. */
export type PulseQuotaWindowStanding =
  | { readonly kind: 'exhausted'; readonly resetsAt: number }
  | { readonly kind: 'spent_reset_unknown'; readonly observedAt: number }
  | { readonly kind: 'reset_since_report'; readonly resetsAt: number }
  | { readonly kind: 'room_left' }
  | { readonly kind: 'no_limit' }

export interface PulseQuotaSummary {
  /** Spent windows whose reset is still ahead of now. */
  readonly exhausted: number
  /** The earliest reset among {@link exhausted} windows. */
  readonly nextReturnAt: number | null
  /** Spent windows whose provider stated no reset time. */
  readonly spentResetUnknown: number
  /** Fraction/percent windows with room, and unlimited credit. */
  readonly subscription: number
}

export interface PulseApprovalItem {
  readonly approval_id: string
  readonly keeper: string
  readonly tool_call_id: string
  readonly tool: string
  readonly question: string
  /** Why the call was held for approval; `null` when the server sent none. */
  readonly because: string | null
  readonly asked_at: number | null
  /** Seconds after `asked_at` the wait times out; `null` when not sent. */
  readonly timeout_sec: number | null
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
  /** `null` when the server sent no phase: shown as unknown, never guessed. */
  readonly phase: string | null
  readonly task_count: number
  readonly task_done_count: number
  readonly awaiting_verification_count: number
  /** Pending approvals on this goal and every sub-goal below it. */
  readonly pending_approval_count: number
  readonly sub_goal_count: number
  readonly verification_status: string | null
  readonly linked_keeper_names: readonly string[]
  readonly updated_at: string | null
}

export type PulseGoalsSnapshot =
  | {
      readonly state: 'ready'
      readonly goals: readonly PulseGoalSummary[]
      /** `summary.pending_approvals`; `null` when the summary did not carry it. */
      readonly pending_approval_total: number | null
    }
  | {
      /** The pending-approval queue could not be read, so the goal tree was not built. */
      readonly state: 'approval_queue_unavailable'
      readonly title: string
      readonly detail: string
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
      readonly quota: PulseQuotaSummary
      readonly unreportedCount: number
    }
  | { readonly kind: 'subscription_zero'; readonly quota: PulseQuotaSummary }
  | { readonly kind: 'exhausted_zero'; readonly quota: PulseQuotaSummary }
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
  /** Seconds until the wait times out (negative once past); `null` when unknown. */
  readonly expiresInSec: number | null
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
