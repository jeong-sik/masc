// --- Gate / HITL ---

import type { KeeperResolvedApprovalDecision } from '../lib/keeper-approval-decision'
export type { KeeperResolvedApprovalDecision } from '../lib/keeper-approval-decision'

// Wire emit: `lib/dashboard/dashboard_http_monitoring.ml:143–149,170,
//   195–199,226` — alert_level is computed as exactly one of
//   {"ok","warn","bad"}. The previous `| string` catch-all hid this
//   closed vocabulary and let unmapped values flow through.
export type DashboardAlertLevel = 'ok' | 'warn' | 'bad'

export interface BoardMonitoring {
  alert_level?: DashboardAlertLevel
  posts_total?: number
  new_posts_24h?: number
  unanswered_posts?: number
  last_activity_age_s?: number | null
  slo_target_age_s?: number
  slo_breached?: boolean
}

export interface PendingConfirmation {
  confirm_token: string
  trace_id: string
  actor: string
  action_type: string
  target_type: string
  target_id: string | null
  payload: Record<string, unknown>
  delegated_tool: string
  created_at: string
  expires_at: string | null
}

export interface PendingConfirmEnvelope {
  items: PendingConfirmation[]
  summary: PendingConfirmSummary
}

export type GateDecisionSource = 'always_allowed' | 'auto_judge' | 'human_operator'
export type GateJudgment = 'approve' | 'deny' | 'require_human'

export type KeeperApprovalAuditEvent =
  | 'pending'
  | 'resolved'
  | 'summary_updated'
  | 'rule_created'
  | 'rule_deleted'
  | 'grant_consumed'
  | 'gate_allowed'
  | 'gate_exact_rule_expired'
  | 'gate_exact_rule_store_degraded'
  | 'gate_grant_unavailable'
  | 'auto_judge_operator_retry_started'
  | 'auto_judge_block_observation_superseded'
  | 'auto_judge_restart_worker_recovered'
  | 'auto_judge_restart_judgment_recovered'

export type KeeperApprovalAuditReceipt =
  | {
      event: KeeperApprovalAuditEvent
      recorded: true
      cleanup_failure?: {
        stage: 'append_cleanup'
        detail: string
      }
    }
  | {
      event: KeeperApprovalAuditEvent
      recorded: false
      stage: 'store_create' | 'append'
      detail: string
    }

export type KeeperApprovalAuditFailure = Extract<
  KeeperApprovalAuditReceipt,
  { recorded: false }
>

export interface KeeperApprovalAuditFailureNotice {
  id: string | null
  transport: 'http' | 'sse'
  observed_at: string
  receipt: KeeperApprovalAuditFailure
}

/** LLM-generated operator briefing attached to a pending approval by the HITL
 *  context-summary worker (`hitl_summary_worker.ml`). Mirrors
 *  `keeper_approval_queue_rules_types.ml:hitl_context_summary`. */
export interface HitlContextSummary {
  summary_version: number
  generated_at: string | null
  model_run_id: string | null
  context_summary: string
  key_questions: string[]
  judgment: GateJudgment
  rationale: string
}

/** Discriminated union mirroring the backend `summary_status` variant
 *  (`keeper_approval_queue_rules_types.ml:summary_status`). `available` carries
 *  the briefing the operator reads before deciding; `pending`/`failed` are
 *  in-flight/error states worth surfacing rather than hiding. */
export type HitlSummaryStatus =
  | { status: 'not_requested' }
  | { status: 'pending' }
  | { status: 'available'; summary: HitlContextSummary }
  | { status: 'failed'; reason: string }

export type KeeperExactAttemptStatus =
  | 'dispatch_uncertain'
  | 'released_before_dispatch'
  | 'released_recovery_required'
  | 'quarantined'
  | 'restart_quarantined'
  | 'completed'

export type KeeperExactAttemptQuarantineCause =
  | 'flow_execution_failed'
  | 'cancellation'
  | 'attempt_replay'
  | 'domain_invalid_output'
  | 'terminal_persistence_failure'

export type KeeperExactAttemptState =
  | { state: 'unbound' }
  | {
      state: 'bound'
      approval_id: string
      input_hash: string
      sequence: number
      slot_id: string
      call_id: string
      plan_fingerprint: string
      request_body_sha256: string
      status: KeeperExactAttemptStatus
      quarantine_cause: KeeperExactAttemptQuarantineCause | null
    }

export type KeeperSummaryAttemptDisposition =
  | { code: 'ready' }
  | { code: 'in_flight' }
  | { code: 'settled' }
  | { code: 'identity_unbound'; operator_detail: string }
  | { code: 'persistence_uncertain'; operator_detail: string }
  | {
      code: 'pre_worker_unavailable'
      reason_code: 'auto_judge_unavailable' | 'mode_state_invalid' | 'start_reserved'
      operator_detail: string
    }

export type KeeperBlockedSummaryAttemptDisposition = Extract<
  KeeperSummaryAttemptDisposition,
  { code: 'identity_unbound' | 'persistence_uncertain' | 'pre_worker_unavailable' }
>

export interface KeeperAutoJudgeRearmExpectation {
  input_hash: string
  sequence: number
  exact_attempt: KeeperExactAttemptState
  summary_attempt_disposition: KeeperBlockedSummaryAttemptDisposition
}

export interface KeeperApprovalQueueItem {
  id: string
  keeper_name: string
  tool_name: string
  input_hash: string
  sequence: number
  requested_at?: string | null
  waiting_s?: number
  turn_id?: number | null
  task_id?: string | null
  goal_id?: string | null
  goal_ids?: string[]
  input?: unknown
  input_preview?: string | null
  summary_status: HitlSummaryStatus
  exact_attempt: KeeperExactAttemptState
  summary_attempt_disposition: KeeperSummaryAttemptDisposition
}

export type KeeperApprovalQueueState =
  | { state: 'ready' }
  | {
      state: 'unavailable'
      code: 'reset_required'
      title: string
      operator_detail: string
      severity: 'bad'
      icon: '!'
    }
  | {
      state: 'observation_error'
      code: 'observation_failed'
      title: string
      operator_detail: string
      severity: 'bad'
      icon: '!'
    }

export interface KeeperResolvedApprovalItem {
  id: string
  keeper_name: string
  tool_name: string
  decision: KeeperResolvedApprovalDecision
  decision_raw: string
  decision_reason: string | null
  resolved_at: string
  turn_id: number | null
  task_id: string | null
  goal_id: string | null
  actor: string | null
  decision_source: GateDecisionSource
  summary_status: HitlSummaryStatus
  exact_attempt: KeeperExactAttemptState
}

/** An approval_queue row the server sent but the client contract rejected.
 *  Rendered as an explicit placeholder instead of blanking the whole queue
 *  (#26094): the operator must know a pending request exists even when its
 *  row cannot be decoded. Identity fields are best-effort salvage. */
export interface KeeperApprovalQueueRowViolation {
  index: number
  id?: string | null
  keeper_name?: string | null
  tool_name?: string | null
}

/** A recent_resolved row the server sent but the client contract rejected.
 *  Surfaced as a typed violation instead of discarding the whole Gate
 *  snapshot (#31695): one undecodable history row must not blind the
 *  operator to the open-Gate count. Identity fields are best-effort salvage. */
export interface KeeperResolvedApprovalRowViolation {
  index: number
  id?: string | null
  keeper_name?: string | null
  tool_name?: string | null
}

/** Which exact-output lane serves Gate Auto Judge. Slot order is Agent Core failover
 *  order: the first slot is the model that actually judges. */
export type GateJudgeLane =
  | { status: 'available'; lane_id: string; slots: string[] }
  | { status: 'unavailable'; lane_id: string; reason: string }

export interface KeeperApprovalRule {
  id: string
  keeper_name: string
  tool_name: string
  request_fingerprint: string
  created_at: number
  created_by: string
  source_approval_id: string
  expires_at: number | null
}

/** One Keeper an operator has held to a stricter mode than the workspace. */
export interface KeeperGateModeOverride {
  keeper_name: string
  mode: GateMode
  updated_by: string
  updated_at: string
}

/** One Keeper pointed at a particular admitted slot for one exact-output lane. */
export interface KeeperExactLanePreference {
  keeper_name: string
  lane_id: string
  slot_id: string
  updated_by: string
  updated_at: string
}

/**
 * Unavailable carries why. An empty list is a working configuration -- nobody
 * singled out -- so a file that cannot be read must not look like one.
 */
export type KeeperGateSettingsState =
  | { state: 'ready' }
  | { state: 'unavailable'; error: string }

export type KeeperApprovalRulesState =
  | { state: 'ready' }
  | { state: 'unavailable'; error: string }

export type GateMode = 'manual' | 'auto_judge' | 'always_allow'

export type GateModeStatus =
  | { mode: GateMode; configured: boolean; state: 'ready' }
  | { mode: 'auto_judge'; configured: boolean; state: 'unavailable'; read_error: string }
  | { mode: 'manual'; configured: true; state: 'invalid'; read_error: string }

/**
 * Bounds that produced `recent_resolved`. Read them with the rows: `returned`
 * alone cannot distinguish a complete history from the newest slice of one.
 * `truncated` means more decisions exist inside the window; `scan_exhausted`
 * means the server's row cap stopped before it reached the window start, so
 * even `matched` is a floor.
 */
export interface KeeperResolvedApprovalPage {
  returned: number
  matched: number
  limit: number
  window_minutes: number
  truncated: boolean
  scan_exhausted: boolean
}

export type KeeperResolvedApprovalState =
  | { state: 'ready' }
  | { state: 'unavailable'; stage: 'list_recent_resolved'; error: string }

export interface DashboardGateResponse {
  generated_at?: string
  note?: string
  approval_queue: KeeperApprovalQueueItem[] | null
  approval_queue_state: KeeperApprovalQueueState
  approval_queue_violations?: KeeperApprovalQueueRowViolation[]
  recent_resolved_violations?: KeeperResolvedApprovalRowViolation[]
  recent_resolved: KeeperResolvedApprovalItem[] | null
  recent_resolved_page: KeeperResolvedApprovalPage | null
  recent_resolved_state: KeeperResolvedApprovalState
  approval_rules: KeeperApprovalRule[]
  approval_rules_state: KeeperApprovalRulesState
  keeper_modes: KeeperGateModeOverride[]
  keeper_modes_state: KeeperGateSettingsState
  keeper_exact_lanes: KeeperExactLanePreference[]
  keeper_exact_lanes_state: KeeperGateSettingsState
  hitl: {
    gate_mode: GateModeStatus
    /** The external-services lane: calls that leave for an attached outside
     *  service (Jira, Slack, GitHub through a Keeper identity). A separate
     *  switch from `gate_mode` on purpose — opening the workspace lane must
     *  not silently open writes into somebody else's service. Absent state
     *  file defaults to manual server-side. */
    external_gate_mode: GateModeStatus
    judge_lane: GateJudgeLane
  } | null
}

export interface OperatorActionDescriptor {
  action_type: string
  tool_name: string
  target_type: string
  description: string
  confirm_required: boolean
}

export interface PendingConfirmSummary {
  actor_filter: string | null
  filter_active: boolean
  visible_count: number
  total_count: number
  hidden_count: number
  hidden_actors: string[]
  confirm_required_actions: OperatorActionDescriptor[]
}
