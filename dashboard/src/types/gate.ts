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
  actor?: string
  action_type?: string
  target_type?: string
  target_id?: string | null
  delegated_tool?: string
  created_at?: string
  preview?: unknown
}

export interface PendingConfirmEnvelope {
  items: PendingConfirmation[]
  summary: PendingConfirmSummary
}

export type GateDecisionSource = 'always_allowed' | 'auto_judge' | 'human_operator'
export type GateJudgment = 'approve' | 'deny' | 'require_human'

/** LLM-generated operator briefing attached to a pending approval by the HITL
 *  context-summary worker (`hitl_summary_worker.ml`). Mirrors
 *  `keeper_approval_queue_types.ml:hitl_context_summary`. */
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
 *  (`keeper_approval_queue_types.ml:summary_status`). `available` carries
 *  the briefing the operator reads before deciding; `pending`/`failed` are
 *  in-flight/error states worth surfacing rather than hiding. */
export type HitlSummaryStatus =
  | { status: 'not_requested' }
  | { status: 'pending' }
  | { status: 'available'; summary: HitlContextSummary }
  | { status: 'failed'; reason: string; retryable: boolean }

export interface KeeperApprovalQueueItem {
  id: string
  keeper_name: string
  tool_name: string
  requested_at?: string | null
  waiting_s?: number
  turn_id?: number | null
  task_id?: string | null
  goal_id?: string | null
  goal_ids?: string[]
  input?: unknown
  input_preview?: string | null
  /** HITL operator briefing state. `null` when the backend payload omits it or
   *  the wire shape violates the contract — never coerced into a fake state. */
  summary_status?: HitlSummaryStatus | null
}

export interface KeeperResolvedApprovalItem {
  id: string
  keeper_name: string
  tool_name: string
  decision: KeeperResolvedApprovalDecision
  decision_raw?: string | null
  decision_reason?: string | null
  resolved_at?: string | null
  turn_id?: number | null
  task_id?: string | null
  goal_id?: string | null
  goal_ids?: string[]
  decision_source?: GateDecisionSource | null
}

export type GateMode = 'manual' | 'auto_judge' | 'always_allow'

export interface GateModeStatus {
  mode: GateMode
  configured?: boolean
  state?: 'ready' | 'invalid' | string
  read_error?: string
}

export interface DashboardGateResponse {
  generated_at?: string
  note?: string
  approval_queue?: KeeperApprovalQueueItem[]
  recent_resolved?: KeeperResolvedApprovalItem[]
  hitl?: {
    gate_mode?: GateModeStatus
  }
}

export interface OperatorActionDescriptor {
  action_type: string
  target_type: string
  description?: string
  confirm_required?: boolean
}

export interface PendingConfirmSummary {
  actor_filter?: string | null
  filter_active: boolean
  visible_count: number
  total_count: number
  hidden_count: number
  hidden_actors: string[]
  confirm_required_actions: OperatorActionDescriptor[]
}
