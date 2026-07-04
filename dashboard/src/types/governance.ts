// --- Governance ---

import type { KeeperResolvedApprovalDecision } from '../lib/keeper-approval-decision'
export type { KeeperResolvedApprovalDecision } from '../lib/keeper-approval-decision'

export interface GovernanceContextRef {
  board_post_id?: string | null
  task_id?: string | null
  operation_id?: string | null
}

export interface GovernanceResolvedAction {
  action_kind?: string
  resolved_tool?: string | null
  target_type?: string | null
  target_id?: string | null
  reason?: string
  payload_preview?: unknown
}

export interface GovernanceExecutedRoute {
  action_type?: string
  tool_name?: string | null
  confirmation_state?: string
  created_at?: string | null
}

export interface GovernanceGuardrailState {
  requires_human_gate?: boolean
  pending_confirm?: PendingConfirmation | null
  pending_confirm_token?: string | null
  ready_to_execute?: boolean
}

export interface PendingConfirmEnvelope {
  items: PendingConfirmation[]
  summary: PendingConfirmSummary
}

export interface GovernanceJudgment {
  judgment_id?: string
  target_kind?: string
  target_id?: string
  status?: string
  summary?: string
  confidence?: number | null
  generated_at?: string | null
  expires_at?: string | null
  model_used?: string | null
  keeper_name?: string | null
  evidence_refs?: string[]
  recommended_action?: GovernanceResolvedAction | null
  guardrail_state?: GovernanceGuardrailState | null
  executed_route?: GovernanceExecutedRoute | null
}

export interface GovernanceDecisionItem {
  kind: 'case' | 'petition'
  id: string
  topic: string
  status: string
  origin?: string | null
  subject_type?: string | null
  risk_class?: 'low' | 'high' | string | null
  provenance?: string | null
  auto_execution_state?: string | null
  petition_count?: number
  brief_count?: number
  last_activity_at?: string | null
  truth_summary?: string
  judgment_summary?: string | null
  confidence?: number | null
  related_agents: string[]
  context?: GovernanceContextRef
  linked_board_post_id?: string | null
  linked_task_id?: string | null
  linked_operation_id?: string | null
  linked_session_id?: string | null
  recommended_action?: GovernanceResolvedAction | null
  executed_route?: GovernanceExecutedRoute | null
  guardrail_state?: GovernanceGuardrailState | null
  evidence_refs: string[]
}

interface GovernancePetition {
  id: string
  case_id: string
  title: string
  origin?: string | null
  subject_type?: string | null
  risk_class?: 'low' | 'high' | string | null
  source_refs: string[]
  created_by?: string | null
  created_at?: string | null
}

interface GovernanceCaseBrief {
  id: string
  author: string
  stance: 'support' | 'oppose' | 'neutral'
  summary: string
  evidence_refs: string[]
  created_at?: string | null
}

interface GovernanceExecutionOrder {
  id: string
  case_id: string
  status: 'queued_auto' | 'needs_human_gate' | 'auto_executed' | 'done' | 'denied' | 'blocked'
  risk_class?: 'low' | 'high' | string | null
  action_request?: GovernanceResolvedAction | null
  created_at?: string | null
  updated_at?: string | null
  execution_ref?: string | null
  result_summary?: string | null
  actor?: string | null
}

export interface GovernanceCaseBundle {
  case: {
    id: string
    petition_ids: string[]
    title: string
    origin?: string | null
    subject_type?: string | null
    risk_class?: 'low' | 'high' | string | null
    status: string
    created_at?: string | null
    updated_at?: string | null
    source_refs: string[]
    briefs: GovernanceCaseBrief[]
  }
  petitions: GovernancePetition[]
  ruling?: GovernanceJudgment | null
  execution_order?: GovernanceExecutionOrder | null
}

export interface GovernanceTimelineEvent {
  kind: string
  item_kind?: string
  item_id?: string
  topic?: string
  created_at?: string | null
  summary?: string
  actor?: string | null
  index?: number
  decision?: string | null
}

export interface GovernanceJudgeSummary {
  judge_online?: boolean
  refreshing?: boolean
  status?: 'online' | 'refreshing' | 'stale_visible' | 'offline' | 'backoff'
  degraded_reason?: 'timeout' | 'error' | 'backoff' | null
  cached_judgments_visible?: boolean
  generated_at?: string | null
  expires_at?: string | null
  model_used?: string | null
  keeper_name?: string | null
  last_error?: string | null
}

// Wire emit: `lib/dashboard/dashboard_http_monitoring.ml:143–149,170,
//   195–199,226` — alert_level is computed as exactly one of
//   {"ok","warn","bad"}. The previous `| string` catch-all hid this
//   closed vocabulary and let unmapped values flow through.
export type GovernanceAlertLevel = 'ok' | 'warn' | 'bad'

export interface BoardMonitoring {
  alert_level?: GovernanceAlertLevel
  posts_total?: number
  new_posts_24h?: number
  unanswered_posts?: number
  last_activity_age_s?: number | null
  slo_target_age_s?: number
  slo_breached?: boolean
}

export interface GovernanceMonitoring {
  alert_level?: GovernanceAlertLevel
  note?: string
  cases_open?: number
  pending_ruling?: number
  ready_auto_execute?: number
  needs_human_gate?: number
  executed?: number
  blocked?: number
  oldest_open_case_age_s?: number | null
  last_activity_age_s?: number | null
  slo_target_case_age_s?: number
  slo_breached?: boolean
  judge_online?: boolean
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

// Wire emit: `lib/governance_pipeline_types.ml:1–18` —
//   `type risk_level = Low | Medium | High | Critical`,
//   `risk_level_to_string` produces exactly these four lowercase strings.
//   Same vocabulary at `lib/keeper/keeper_approval_queue.ml:49–53` and
//   serialized at `:814`. Frontend was untyped `string`.
export type KeeperApprovalRiskLevel = 'low' | 'medium' | 'high' | 'critical'

/** One operator option proposed by the HITL context-summary worker.
 *  Mirrors `keeper_approval_queue_rules_types.ml:suggested_option`. */
export interface HitlSuggestedOption {
  label: string
  rationale: string
  estimated_risk_delta: KeeperApprovalRiskLevel | null
}

/** LLM-generated operator briefing attached to a pending approval by the HITL
 *  context-summary worker (`hitl_summary_worker.ml`). Mirrors
 *  `keeper_approval_queue_rules_types.ml:hitl_context_summary`. */
export interface HitlContextSummary {
  summary_version: number
  generated_at_iso: string | null
  model_run_id: string | null
  context_summary: string
  key_questions: string[]
  suggested_options: HitlSuggestedOption[]
  risk_rationale: string | null
  uncertainty: number | null
}

/** Discriminated union mirroring the backend `summary_status` variant
 *  (`keeper_approval_queue_rules_types.ml:summary_status`). `available` carries
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
  action_key?: string | null
  sandbox_target?: string | null
  risk_level: KeeperApprovalRiskLevel
  requested_at?: string | null
  waiting_s?: number
  turn_id?: number | null
  task_id?: string | null
  goal_id?: string | null
  goal_ids?: string[]
  runtime_contract?: {
    sandbox_profile?: string | null
    network_mode?: string | null
    backend?: string | null
    task_id?: string | null
    goal_id?: string | null
    goal_ids?: string[]
  } | null
  selected_model?: string | null
  disposition?: string | null
  disposition_reason?: string | null
  decision?: string | null
  rule_match?: {
    rule_id?: string | null
    matched_by?: string | null
  } | null
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
  risk_level?: KeeperApprovalRiskLevel | null
  decision: KeeperResolvedApprovalDecision
  decision_raw?: string | null
  decision_reason?: string | null
  resolved_at?: string | null
  turn_id?: number | null
  task_id?: string | null
  goal_id?: string | null
  goal_ids?: string[]
  sandbox_target?: string | null
  disposition?: string | null
  disposition_reason?: string | null
  rule_match?: {
    rule_id?: string | null
    matched_by?: string | null
  } | null
}

export interface KeeperApprovalRule {
  id: string
  keeper_name: string
  tool_name: string
  sandbox_profile?: string | null
  backend?: string | null
  request_fingerprint?: string
  request_fingerprint_preview?: string
  /** Same vocabulary as `KeeperApprovalRiskLevel` (backend
   *  `risk_level_to_string` ∈ {low, medium, high, critical}). */
  max_risk?: KeeperApprovalRiskLevel
  created_at?: string | null
  created_by?: string | null
  last_matched_at?: string | null
  match_count?: number
  source_approval_id?: string | null
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
